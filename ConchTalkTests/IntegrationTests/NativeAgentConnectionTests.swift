/// 文件说明：NativeAgentConnectionTests，诊断 Citadel TTY/PTY 通道在 Claude Code 场景下的 stdout 输出问题。

@testable import ConchTalk
@preconcurrency import Citadel
import Foundation
import NIOCore
import NIOFoundationCompat
import NIOSSH
import Testing

/// NativeAgentConnectionTests：
/// 逐层验证 Citadel SSH 通道能否正确接收远端进程的 stdout 输出。
/// 从最简单的 echo 命令开始，逐步升级到 Claude Code CLI，定位 readLoop 挂起的根因。
///
/// 已知发现：
/// - Citadel TTY（exec channel）和 PTY 通道均能正常接收 Claude Code 的 stdout
/// - Claude Code `-p` (print mode) 需要 stdin 传入 prompt 或命令行提供 prompt 参数
/// - `--input-format stream-json` 模式下，Claude Code 等待 stdin 上的 JSON 输入
/// - 如果 TTY 通道上 stdin 没有正确写入 prompt JSON，Claude Code 会一直等待（表现为 hang）
/// - `sh -c 'cd ... && exec claude ...'` 的包装方式本身不会阻塞 stdout
///
/// 注意：由于 Citadel SSHClient 的连接生命周期管理，在 `.serialized` 测试套件中
/// 快速连续创建/关闭 SSH 连接可能导致 "Already closed" 错误。
/// 每个测试独立创建连接并在使用完毕后同步断开，避免 defer 中的异步 disconnect 竞争。
@Suite(.tags(.integration), .serialized, .enabled(if: IntegrationTestConfig.isAvailable))
struct NativeAgentConnectionTests {

    // MARK: - 辅助方法

    /// 创建独立的 SSH 连接，执行闭包后同步断开。
    private func withSSHConnection<T: Sendable>(
        _ body: @Sendable (SSHClient) async throws -> T
    ) async throws -> T {
        // 短暂等待，让前一个测试的 SSH 连接完全关闭
        try await Task.sleep(for: .seconds(1))

        let config = try #require(IntegrationTestConfig.load())
        let nioClient = try await config.connectSSH()
        guard let citadel = await nioClient.citadelClient else {
            throw SSHError.notConnected
        }
        do {
            let result = try await body(citadel)
            await nioClient.disconnect()
            return result
        } catch {
            await nioClient.disconnect()
            throw error
        }
    }

    // MARK: - Test 1: executeCommand 基线

    /// 使用 Citadel 的 executeCommand 验证基本 SSH 连接。
    @Test(.timeLimit(.minutes(1)))
    func executeCommandEcho() async throws {
        _ = try await withSSHConnection { client in
            let output = try await client.executeCommand("echo HELLO_EXEC_TEST")
            let text = String(data: Data(buffer: output), encoding: .utf8) ?? ""
            print("[Test] executeCommand output: \(text)")
            #expect(text.contains("HELLO_EXEC_TEST"), "executeCommand should return echo output")
            return true
        }
    }

    // MARK: - Test 2: TTY + echo

    /// 验证 withTTY exec channel 能否接收简单 echo 命令的 stdout。
    @Test(.timeLimit(.minutes(1)))
    func ttyEchoCommand() async throws {
        _ = try await withSSHConnection { client in
            nonisolated(unsafe) var receivedChunks: [String] = []

            do {
                try await client.withTTY { inbound, outbound in
                    try await outbound.write(ByteBuffer(string: "echo 'HELLO_TTY_TEST'; exit 0\n"))

                    for try await chunk in inbound {
                        switch chunk {
                        case .stdout(let buf):
                            let text = String(data: Data(buffer: buf), encoding: .utf8) ?? ""
                            print("[Test] TTY stdout: \(text.debugDescription)")
                            receivedChunks.append(text)
                        case .stderr(let buf):
                            let text = String(data: Data(buffer: buf), encoding: .utf8) ?? ""
                            if !text.isEmpty { print("[Test] TTY stderr: \(text.debugDescription)") }
                        }
                    }
                }
            } catch {
                // `exit 0` 导致 shell 退出，Citadel 通道关闭可能抛 "Already closed"
                print("[Test] TTY channel closed: \(error)")
            }

            let allOutput = receivedChunks.joined()
            print("[Test] TTY total stdout: \(allOutput.count) bytes")
            #expect(allOutput.contains("HELLO_TTY_TEST"), "TTY channel should receive echo output")
            return true
        }
    }

    // MARK: - Test 3: executeCommand + claude --version

    /// 验证 Claude Code CLI 可达。
    @Test(.timeLimit(.minutes(1)))
    func executeCommandClaudeVersion() async throws {
        _ = try await withSSHConnection { client in
            let fullCommand = SSHSessionManager.shellInitPrefix + "claude --version"
            let output = try await client.executeCommand(fullCommand)
            let text = String(data: Data(buffer: output), encoding: .utf8) ?? ""
            print("[Test] claude --version: \(text)")
            #expect(!text.isEmpty, "executeCommand should return claude version")
            return true
        }
    }

    // MARK: - Test 4: TTY + Claude Code stream-json with sh -c（复现实际 bug）

    /// 复现 ClaudeCodeConnection 的挂起问题：
    /// 使用与 ClaudeCodeConnection.connect() 完全相同的命令构造方式。
    ///
    /// 预期行为：Claude Code 启动后输出 system init 等 JSON 消息到 stdout。
    /// 实际行为（bug）：如果 stdout 未收到数据，说明 Citadel TTY 通道有问题。
    @Test(.timeLimit(.minutes(2)))
    func ttyClaudeCodeStreamJsonWithShWrapper() async throws {
        _ = try await withSSHConnection { client in
            nonisolated(unsafe) var receivedStdout: [String] = []
            nonisolated(unsafe) var receivedStderr: [String] = []
            nonisolated(unsafe) var gotSystemInit = false

            // 与 ClaudeCodeConnection.connect() 相同的命令构造
            let claudeFlags = "-p --output-format stream-json --input-format stream-json --verbose"
            let innerCommand = "sh -c 'cd ~ && exec claude \(claudeFlags)'"
            let fullCommand = SSHSessionManager.shellInitPrefix + "exec \(innerCommand)"

            print("[Test] === TTY + sh -c wrapper (same as ClaudeCodeConnection) ===")
            print("[Test] Full command: \(fullCommand)")

            let completed = try await withThrowingTaskGroup(of: Bool.self) { group in
                group.addTask {
                    try await client.withTTY { inbound, outbound in
                        try await outbound.write(ByteBuffer(string: "\(fullCommand)\n"))
                        print("[Test] Command sent, waiting for output...")

                        for try await chunk in inbound {
                            switch chunk {
                            case .stdout(let buf):
                                let text = String(data: Data(buffer: buf), encoding: .utf8) ?? ""
                                print("[Test] STDOUT (\(text.count) bytes): \(text.prefix(300))")
                                receivedStdout.append(text)
                                if text.contains("\"subtype\":\"init\"") {
                                    gotSystemInit = true
                                    // 收到 init 后退出
                                    try await outbound.write(ByteBuffer(string: "\u{03}\u{04}"))
                                }
                            case .stderr(let buf):
                                let text = String(data: Data(buffer: buf), encoding: .utf8) ?? ""
                                if !text.isEmpty {
                                    print("[Test] STDERR: \(text.prefix(300))")
                                    receivedStderr.append(text)
                                }
                            }
                        }
                    }
                    return true
                }

                group.addTask {
                    try await Task.sleep(for: .seconds(60))
                    return false
                }

                let first = try await group.next() ?? false
                group.cancelAll()
                return first
            }

            let totalStdout = receivedStdout.joined()
            let totalStderr = receivedStderr.joined()
            print("[Test] === TTY+SH-C DIAGNOSTIC ===")
            print("[Test] Completed normally (not timeout): \(completed)")
            print("[Test] Stdout bytes: \(totalStdout.count)")
            print("[Test] Stderr bytes: \(totalStderr.count)")
            print("[Test] Got system.init: \(gotSystemInit)")
            if totalStdout.count > 0 { print("[Test] Stdout first 1000: \(totalStdout.prefix(1000))") }
            if totalStderr.count > 0 { print("[Test] Stderr first 500: \(totalStderr.prefix(500))") }

            // 诊断断言：至少应该收到 stdout 或 stderr 输出
            #expect(!totalStdout.isEmpty || !totalStderr.isEmpty,
                    "Should receive some output from Claude Code via TTY + sh -c wrapper")
            return true
        }
    }

    // MARK: - Test 5: TTY + Claude Code 直接运行（不用 sh -c 包装）

    /// 去掉 sh -c 包装，直接运行 claude。
    /// 对比 Test 4，定位问题是否由 sh -c + exec 嵌套导致。
    @Test(.timeLimit(.minutes(2)))
    func ttyClaudeDirectNoShWrapper() async throws {
        _ = try await withSSHConnection { client in
            nonisolated(unsafe) var receivedStdout: [String] = []
            nonisolated(unsafe) var receivedStderr: [String] = []
            nonisolated(unsafe) var gotSystemInit = false

            let claudeFlags = "-p --output-format stream-json --input-format stream-json --verbose"
            let fullCommand = SSHSessionManager.shellInitPrefix + "exec claude \(claudeFlags)"

            print("[Test] === TTY + direct claude (no sh -c) ===")
            print("[Test] Full command: \(fullCommand)")

            let completed = try await withThrowingTaskGroup(of: Bool.self) { group in
                group.addTask {
                    try await client.withTTY { inbound, outbound in
                        try await outbound.write(ByteBuffer(string: "\(fullCommand)\n"))

                        for try await chunk in inbound {
                            switch chunk {
                            case .stdout(let buf):
                                let text = String(data: Data(buffer: buf), encoding: .utf8) ?? ""
                                print("[Test] STDOUT (\(text.count) bytes): \(text.prefix(300))")
                                receivedStdout.append(text)
                                if text.contains("\"subtype\":\"init\"") {
                                    gotSystemInit = true
                                    try await outbound.write(ByteBuffer(string: "\u{03}\u{04}"))
                                }
                            case .stderr(let buf):
                                let text = String(data: Data(buffer: buf), encoding: .utf8) ?? ""
                                if !text.isEmpty {
                                    print("[Test] STDERR: \(text.prefix(300))")
                                    receivedStderr.append(text)
                                }
                            }
                        }
                    }
                    return true
                }

                group.addTask {
                    try await Task.sleep(for: .seconds(60))
                    return false
                }

                let first = try await group.next() ?? false
                group.cancelAll()
                return first
            }

            let totalStdout = receivedStdout.joined()
            let totalStderr = receivedStderr.joined()
            print("[Test] === DIRECT COMMAND DIAGNOSTIC ===")
            print("[Test] Completed normally (not timeout): \(completed)")
            print("[Test] Stdout bytes: \(totalStdout.count)")
            print("[Test] Stderr bytes: \(totalStderr.count)")
            print("[Test] Got system.init: \(gotSystemInit)")
            if totalStdout.count > 0 { print("[Test] Stdout first 1000: \(totalStdout.prefix(1000))") }
            if totalStderr.count > 0 { print("[Test] Stderr first 500: \(totalStderr.prefix(500))") }

            #expect(!totalStdout.isEmpty || !totalStderr.isEmpty,
                    "Direct claude command should produce output via TTY")
            return true
        }
    }

    // MARK: - Test 6: PTY + Claude Code stream-json

    /// 用 PTY 通道运行 Claude Code，对比 TTY 的行为。
    /// PTY 提供完整终端仿真，对调试 stdin/stdout 行为差异有帮助。
    @Test(.timeLimit(.minutes(2)))
    func ptyClaudeCodeStreamJson() async throws {
        _ = try await withSSHConnection { client in
            nonisolated(unsafe) var receivedStdout: [String] = []
            nonisolated(unsafe) var receivedStderr: [String] = []
            nonisolated(unsafe) var gotSystemInit = false

            let claudeFlags = "-p --output-format stream-json --input-format stream-json --verbose"
            let innerCommand = "sh -c 'cd ~ && exec claude \(claudeFlags)'"
            let fullCommand = SSHSessionManager.shellInitPrefix + "exec \(innerCommand)"

            let ptyRequest = SSHChannelRequestEvent.PseudoTerminalRequest(
                wantReply: true,
                term: "xterm-256color",
                terminalCharacterWidth: 32768,
                terminalRowHeight: 24,
                terminalPixelWidth: 0,
                terminalPixelHeight: 0,
                terminalModes: .init([:])
            )

            print("[Test] === PTY + sh -c wrapper ===")
            print("[Test] Full command: \(fullCommand)")

            // Claude Code 在 --print 模式下如果没有 stdin 输入会主动退出，
            // 导致 PTY 通道关闭并抛出 "Already closed"。这是预期行为，不应导致测试失败。
            let completed = try await withThrowingTaskGroup(of: Bool.self) { group in
                group.addTask {
                    do {
                        try await client.withPTY(ptyRequest) { inbound, outbound in
                            try await outbound.write(ByteBuffer(string: "\(fullCommand)\n"))

                            for try await chunk in inbound {
                                switch chunk {
                                case .stdout(let buf):
                                    let text = String(data: Data(buffer: buf), encoding: .utf8) ?? ""
                                    print("[Test] PTY STDOUT (\(text.count) bytes): \(text.prefix(300))")
                                    receivedStdout.append(text)
                                    if text.contains("\"subtype\":\"init\"") {
                                        gotSystemInit = true
                                        try await outbound.write(ByteBuffer(string: "\u{03}\u{04}"))
                                    }
                                case .stderr(let buf):
                                    let text = String(data: Data(buffer: buf), encoding: .utf8) ?? ""
                                    if !text.isEmpty {
                                        print("[Test] PTY STDERR: \(text.prefix(300))")
                                        receivedStderr.append(text)
                                    }
                                }
                            }
                        }
                    } catch {
                        // Claude Code 退出后 PTY 通道关闭，Citadel 抛 "Already closed" 是正常的
                        print("[Test] PTY channel closed (expected): \(error)")
                    }
                    return true
                }

                group.addTask {
                    try await Task.sleep(for: .seconds(60))
                    return false
                }

                let first = try await group.next() ?? false
                group.cancelAll()
                return first
            }

            let totalStdout = receivedStdout.joined()
            let totalStderr = receivedStderr.joined()
            print("[Test] === PTY DIAGNOSTIC ===")
            print("[Test] Completed normally (not timeout): \(completed)")
            print("[Test] Stdout bytes: \(totalStdout.count)")
            print("[Test] Stderr bytes: \(totalStderr.count)")
            print("[Test] Got system.init: \(gotSystemInit)")
            if totalStdout.count > 0 { print("[Test] Stdout first 1000: \(totalStdout.prefix(1000))") }

            #expect(!totalStdout.isEmpty || !totalStderr.isEmpty,
                    "PTY should receive some output from Claude Code")
            return true
        }
    }
}
