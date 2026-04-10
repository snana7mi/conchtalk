/// 文件说明：SSHProcessTransport，通用 SSH 进程 stdin/stdout 行传输。

import Foundation
import os
import NIOCore
import NIOFoundationCompat
import NIOSSH
@preconcurrency import Citadel

/// LineBuffer：行缓冲工具，将数据块分割为完整行。
nonisolated struct LineBuffer: Sendable {
    private var buffer = ""

    /// 追加数据，返回完整行（不含换行符）。不完整的尾部保留到下次调用。
    mutating func append(_ text: String) -> [String] {
        // 剥离 PTY 的 \r
        let cleaned = text.replacingOccurrences(of: "\r", with: "")
        buffer += cleaned

        var lines: [String] = []
        while let idx = buffer.firstIndex(of: "\n") {
            let line = String(buffer[buffer.startIndex..<idx])
            buffer = String(buffer[buffer.index(after: idx)...])
            guard !line.isEmpty else { continue }
            lines.append(line)
        }
        return lines
    }

    /// 是否有未处理的残留数据。
    var hasRemainder: Bool { !buffer.isEmpty }
}

/// SSHProcessTransport：通过 SSH 通道启动远端进程，以行为单位收发文本。
/// 与 SSHACPTransport 不同，本类输出原始字符串行（非 ACPMessage），
/// 供 ClaudeCodeConnection / CodexConnection 各自解析原生协议。
actor SSHProcessTransport {
    nonisolated(unsafe) private let sshClient: SSHClient
    nonisolated private let command: String
    /// 是否用 `exec` 替换 shell 进程。默认 true，但当 command 包含 `cd &&` 等复合语句时应设为 false。
    nonisolated private let useExec: Bool
    /// 强制使用 PTY（跳过 TTY 尝试）。需要真终端的命令必须设为 true。
    nonisolated private let forcePTY: Bool
    private var stdinWriter: TTYStdinWriter?
    private var shellTask: Task<Void, Error>?

    private let lineContinuation: AsyncThrowingStream<String, Error>.Continuation
    nonisolated let lines: AsyncThrowingStream<String, Error>

    /// 诊断日志，记录非正常输出（stderr、shell 启动噪声等）。
    nonisolated let diagnosticLog = DiagnosticLog()

    init(sshClient: SSHClient, command: String, useExec: Bool = true, forcePTY: Bool = false) {
        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
        self.sshClient = sshClient
        self.command = command
        self.useExec = useExec
        self.forcePTY = forcePTY
        self.lines = stream
        self.lineContinuation = continuation
    }

    /// 启动远端进程。
    func start() async throws {
        print("[SSHProcessTransport] start() called, command=\(command.prefix(100))")
        // 用 AsyncThrowingStream 从闭包中逃逸 writer
        let (writerStream, writerContinuation) = AsyncThrowingStream<TTYStdinWriter, Error>.makeStream()

        // SSH exec channel 是 non-login shell，先 source 用户 shell 配置加载完整 PATH，
        // 再 exec 进程命令。`exec` 替换 shell 进程，避免退出后 bash 残留。
        let prefix = useExec ? "exec " : ""
        // forcePTY 时禁用终端回显：PTY 默认会将 stdin 输入回显到 stdout，
        // 导致 JSON-RPC 请求被回显混入响应流干扰解析。
        let echoOff = forcePTY ? "stty -echo; " : ""
        let fullCommand = SSHSessionManager.shellInitPrefix + echoOff + "\(prefix)\(command)"
        print("[SSHProcessTransport] fullCommand=\(fullCommand.prefix(200))")
        let continuation = lineContinuation
        let diagLog = diagnosticLog

        // 使用 Task.detached 避免继承 MainActor 隔离
        let client = sshClient
        let shouldForcePTY = forcePTY
        shellTask = Task.detached {
            // PTY 辅助闭包（需要真终端的命令，或 TTY 不可用时回退）
            // forcePTY 用 500 列：终端程序会按宽度重绘屏幕，
            // 32768 列 × 24 行 = ~786KB 空格数据会堵塞管道。
            // 500 列足够 JSON 行不被折断，初始重绘仅 ~12KB。
            // 非 forcePTY 的 PTY fallback 保持 32768，因为直连进程不渲染终端屏幕。
            let ptyWidth: Int = shouldForcePTY ? 500 : 32768
            @Sendable func launchWithPTY() async throws {
                print("[SSHProcessTransport] Using PTY mode (width=\(ptyWidth))")
                let ptyRequest = SSHChannelRequestEvent.PseudoTerminalRequest(
                    wantReply: true,
                    term: "xterm-256color",
                    terminalCharacterWidth: ptyWidth,
                    terminalRowHeight: 24,
                    terminalPixelWidth: 0,
                    terminalPixelHeight: 0,
                    terminalModes: .init([:])
                )
                try await client.withPTY(ptyRequest) { inbound, outbound in
                    writerContinuation.yield(outbound)
                    writerContinuation.finish()
                    try await outbound.write(ByteBuffer(string: "\(fullCommand)\n"))
                    await Self.readLoop(inbound: inbound, continuation: continuation, diagnosticLog: diagLog)
                }
            }

            // forcePTY 时直接走 PTY（需要真终端的命令）
            if shouldForcePTY {
                do {
                    try await launchWithPTY()
                } catch {
                    writerContinuation.finish(throwing: error)
                    continuation.finish(throwing: error)
                    return
                }
            } else {
                // 默认优先使用 TTY（exec channel），避免 PTY 在 80 列处自动换行导致行被截断。
                var usedTTY = false
                do {
                    try await client.withTTY { inbound, outbound in
                        usedTTY = true
                        writerContinuation.yield(outbound)
                        writerContinuation.finish()
                        try await outbound.write(ByteBuffer(string: "\(fullCommand)\n"))
                        await Self.readLoop(inbound: inbound, continuation: continuation, diagnosticLog: diagLog)
                    }
                } catch {
                    if !usedTTY {
                        // TTY 不可用，回退到 PTY
                        print("[SSHProcessTransport] TTY unavailable, falling back to PTY")
                        do {
                            try await launchWithPTY()
                        } catch {
                            writerContinuation.finish(throwing: error)
                            continuation.finish(throwing: error)
                            return
                        }
                    } else {
                        // TTY 闭包内部出错
                        writerContinuation.finish(throwing: error)
                        continuation.finish(throwing: error)
                        return
                    }
                }
            }
            continuation.finish()
        }

        // 等待 writer 就绪
        print("[SSHProcessTransport] waiting for writer...")
        var writerIterator = writerStream.makeAsyncIterator()
        guard let writer = try await writerIterator.next() else {
            throw ACPTransportError.notConnected
        }
        stdinWriter = writer
        print("[SSHProcessTransport] writer ready, start() complete")
    }

    /// 向远端进程 stdin 写入一行文本（自动追加换行符）。
    func writeLine(_ text: String) async throws {
        guard let writer = stdinWriter else { throw ACPTransportError.notConnected }
        try await writer.write(ByteBuffer(string: text + "\n"))
    }

    /// 向远端进程 stdin 写入原始字节。
    func writeRaw(_ text: String) async throws {
        guard let writer = stdinWriter else { throw ACPTransportError.notConnected }
        try await writer.write(ByteBuffer(string: text))
    }

    /// 关闭传输。
    func close() async {
        // 先尝试优雅关闭：发送中断信号让远端进程自行退出
        await sendGracefulShutdown()

        shellTask?.cancel()
        shellTask = nil
        stdinWriter = nil
        lineContinuation.finish()
    }

    /// 向远端进程发送中断信号，尝试让其优雅退出。
    private func sendGracefulShutdown() async {
        guard let writer = stdinWriter else { return }
        // Ctrl+C (SIGINT)
        try? await writer.write(ByteBuffer(string: "\u{03}"))
        // Ctrl+D (EOF) — 通知远端 stdin 结束
        try? await writer.write(ByteBuffer(string: "\u{04}"))
        // 短暂等待让远端进程响应中断信号
        try? await Task.sleep(for: .milliseconds(200))
    }

    // MARK: - 内部

    /// 从 SSH 通道的 stdout 流逐行读取，产出原始字符串行。
    /// stderr 输出记录到诊断日志。
    private static func readLoop(
        inbound: TTYOutput,
        continuation: AsyncThrowingStream<String, Error>.Continuation,
        diagnosticLog: DiagnosticLog
    ) async {
        var lineBuffer = LineBuffer()

        do {
            print("[SSHProcessTransport] readLoop started, awaiting first chunk...")
            for try await chunk in inbound {
                let text: String
                switch chunk {
                case .stdout(let buf):
                    text = String(data: Data(buffer: buf), encoding: .utf8) ?? ""
                    print("[SSHProcessTransport] stdout chunk: \(text.count) bytes, first80=\(text.prefix(80))")
                case .stderr(let buf):
                    // stderr 记录到诊断日志
                    let stderrText = String(data: Data(buffer: buf), encoding: .utf8) ?? ""
                    if !stderrText.isEmpty {
                        print("[SSHProcessTransport] stderr: \(stderrText.prefix(200))")
                        diagnosticLog.append("[stderr] \(stderrText.trimmingCharacters(in: .whitespacesAndNewlines))")
                    }
                    continue
                }
                guard !text.isEmpty else { continue }

                let lines = lineBuffer.append(text)
                for line in lines {
                    print("[SSHProcessTransport] yielding line: \(line.count) chars")
                    continuation.yield(line)
                }
            }
            // SSH 通道流正常结束（进程退出）
            if lineBuffer.hasRemainder {
                print("[SSHProcessTransport] readLoop ended with unprocessed buffer")
            }
            print("[SSHProcessTransport] readLoop ended normally (process exited)")
        } catch {
            print("[SSHProcessTransport] readLoop error: \(error)")
            continuation.finish(throwing: error)
        }
    }
}
