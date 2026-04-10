/// 文件说明：SSHACPTransport，通过 SSH PTY/TTY 通道传输 ACP JSON-RPC 消息。

import Foundation
import os
@preconcurrency import ACPModel
import NIOCore
import NIOFoundationCompat
import NIOSSH
@preconcurrency import Citadel

/// SSHACPTransport：通过 SSH 通道与远端 ACP 代理进行双向 ND-JSON 通信。
///
/// 使用 Citadel 的 withPTY/withTTY API 打开独立 SSH channel，
/// 在其中运行 ACP 代理进程（如 `claude --acp`），
/// 以换行分隔的 JSON（ND-JSON）格式收发 JSON-RPC 消息。
actor SSHACPTransport: ACPTransport {
    nonisolated(unsafe) private let sshClient: SSHClient
    nonisolated private let agentCommand: String
    private var stdinWriter: TTYStdinWriter?
    private var shellTask: Task<Void, Error>?

    private let messageContinuation: AsyncThrowingStream<ACPMessage, Error>.Continuation
    nonisolated let messages: AsyncThrowingStream<ACPMessage, Error>

    /// 代理启动期间的非 JSON 输出（stderr + stdout 中的非 JSON 行），用于诊断。
    /// 使用线程安全容器，供 readLoop 在 Task.detached 中写入。
    nonisolated let diagnosticLog = DiagnosticLog()

    init(sshClient: SSHClient, agentCommand: String) {
        let (stream, continuation) = AsyncThrowingStream<ACPMessage, Error>.makeStream()
        self.sshClient = sshClient
        self.agentCommand = agentCommand
        self.messages = stream
        self.messageContinuation = continuation
    }

    func start() async throws {
        // 用 AsyncThrowingStream 从闭包中逃逸 writer（复用 ShellChannel 的模式）
        let (writerStream, writerContinuation) = AsyncThrowingStream<TTYStdinWriter, Error>.makeStream()

        // SSH exec channel 是 non-login shell，nvm 等不在 PATH 中。
        // 先 source 用户 shell 配置加载完整 PATH，再 exec agent 命令。
        // `exec` 替换 shell 进程，避免 agent 退出后 bash 残留接收 JSON-RPC 消息。
        let command = SSHSessionManager.shellInitPrefix + "exec \(agentCommand)"
        let msgContinuation = messageContinuation
        let diagLog = diagnosticLog

        // 使用 Task.detached 避免继承 MainActor 隔离
        let client = sshClient
        shellTask = Task.detached {
            // ACP 是纯 JSON-RPC over stdin/stdout，不需要终端仿真。
            // 优先使用 TTY（exec channel），避免 PTY 在 80 列处自动换行导致 JSON 被截断。
            var usedTTY = false
            do {
                try await client.withTTY { inbound, outbound in
                    usedTTY = true
                    writerContinuation.yield(outbound)
                    writerContinuation.finish()
                    try await outbound.write(ByteBuffer(string: "\(command)\n"))
                    await Self.readLoop(inbound: inbound, continuation: msgContinuation, diagnosticLog: diagLog)
                }
            } catch {
                if !usedTTY {
                    // TTY 不可用，回退到 PTY（设置超大宽度尽量避免换行）
                    print("[SSHACPTransport] TTY unavailable, falling back to PTY")
                    let ptyRequest = SSHChannelRequestEvent.PseudoTerminalRequest(
                        wantReply: true,
                        term: "xterm-256color",
                        terminalCharacterWidth: 32768,
                        terminalRowHeight: 24,
                        terminalPixelWidth: 0,
                        terminalPixelHeight: 0,
                        terminalModes: .init([:])
                    )
                    do {
                        try await client.withPTY(ptyRequest) { inbound, outbound in
                            writerContinuation.yield(outbound)
                            writerContinuation.finish()
                            try await outbound.write(ByteBuffer(string: "\(command)\n"))
                            await Self.readLoop(inbound: inbound, continuation: msgContinuation, diagnosticLog: diagLog)
                        }
                    } catch {
                        writerContinuation.finish(throwing: error)
                        msgContinuation.finish(throwing: error)
                        return
                    }
                } else {
                    // TTY 闭包内部出错
                    msgContinuation.finish(throwing: error)
                    return
                }
            }
            msgContinuation.finish()
        }

        // 等待 writer 就绪
        var writerIterator = writerStream.makeAsyncIterator()
        guard let writer = try await writerIterator.next() else {
            throw ACPTransportError.notConnected
        }
        stdinWriter = writer
    }

    func send(_ message: ACPMessage) async throws {
        guard let writer = stdinWriter else {
            throw ACPTransportError.notConnected
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = []  // 单行紧凑 JSON
        let data = try encoder.encode(message)
        guard var jsonString = String(data: data, encoding: .utf8) else {
            throw ACPTransportError.encodingFailed
        }
        jsonString += "\n"
        try await writer.write(ByteBuffer(string: jsonString))
    }

    func close() async {
        // 先尝试优雅关闭：发送中断信号让远端进程自行退出
        await sendGracefulShutdown()

        shellTask?.cancel()
        shellTask = nil
        stdinWriter = nil
        messageContinuation.finish()
    }

    /// 向远端进程发送中断信号，尝试让其优雅退出。
    /// PTY 模式下 Ctrl+C 会被终端驱动转为 SIGINT；TTY 模式下作为字节发送，
    /// 部分代理可能不处理，但 EOF (Ctrl+D) 在两种模式下都能触发 stdin 关闭。
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

    /// 从 SSH 通道的 stdout 流逐行读取，解析为 JSON-RPC 消息。
    /// 跳过非 JSON 行（shell 启动噪声等），并将其记录到诊断日志。
    /// stderr 输出记录到诊断日志（代理启动错误等）。
    private static func readLoop(
        inbound: TTYOutput,
        continuation: AsyncThrowingStream<ACPMessage, Error>.Continuation,
        diagnosticLog: DiagnosticLog
    ) async {
        var buffer = ""
        let decoder = JSONDecoder()

        do {
            for try await chunk in inbound {
                let text: String
                switch chunk {
                case .stdout(let buf):
                    text = String(data: Data(buffer: buf), encoding: .utf8) ?? ""
                case .stderr(let buf):
                    // stderr 记录到诊断日志
                    let stderrText = String(data: Data(buffer: buf), encoding: .utf8) ?? ""
                    if !stderrText.isEmpty {
                        print("[SSHACPTransport] Agent stderr: \(stderrText)")
                        diagnosticLog.append("[stderr] \(stderrText.trimmingCharacters(in: .whitespacesAndNewlines))")
                    }
                    continue
                }
                guard !text.isEmpty else { continue }

                // 剥离 PTY 的 \r，保持纯 \n 换行
                let cleaned = text.replacingOccurrences(of: "\r", with: "")
                buffer += cleaned

                // 按换行分割，处理完整行
                while let newlineIndex = buffer.firstIndex(of: "\n") {
                    let line = String(buffer[buffer.startIndex..<newlineIndex]).trimmingCharacters(in: .whitespaces)
                    buffer = String(buffer[buffer.index(after: newlineIndex)...])

                    guard !line.isEmpty else { continue }

                    // 非 JSON 行记录到诊断日志
                    guard line.hasPrefix("{") else {
                        diagnosticLog.append(line)
                        continue
                    }

                    // 尝试解码 JSON-RPC 消息
                    guard let lineData = line.data(using: .utf8) else { continue }
                    do {
                        let message = try decoder.decode(ACPMessage.self, from: lineData)
                        continuation.yield(message)
                    } catch {
                        print("[SSHACPTransport] Failed to decode JSON-RPC: \(error), line: \(line.prefix(500))")
                    }
                }
            }
            // SSH 通道流正常结束（代理进程退出）
            if !buffer.isEmpty {
                print("[SSHACPTransport] readLoop ended with unprocessed buffer: \(buffer.prefix(300))")
            }
            print("[SSHACPTransport] readLoop ended normally (agent process exited)")
        } catch {
            print("[SSHACPTransport] readLoop error: \(error)")
            continuation.finish(throwing: error)
        }
    }
}

/// DiagnosticLog：线程安全的诊断日志收集器，用于在 readLoop 中捕获非 JSON 输出。
final class DiagnosticLog: Sendable {
    private let storage = OSAllocatedUnfairLock(initialState: [String]())

    nonisolated init() {}

    nonisolated func append(_ line: String) {
        storage.withLock { $0.append(line) }
    }

    nonisolated var lines: [String] {
        storage.withLock { $0 }
    }

    /// 返回合并的诊断文本（截取前 500 字符），用于错误信息展示。
    nonisolated var summary: String {
        let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }
        return String(text.prefix(500))
    }
}

/// ACPTransportError：传输层错误。
nonisolated enum ACPTransportError: LocalizedError, Sendable {
    case notConnected
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .notConnected: return "ACP transport not connected"
        case .encodingFailed: return "Failed to encode JSON-RPC message"
        }
    }
}
