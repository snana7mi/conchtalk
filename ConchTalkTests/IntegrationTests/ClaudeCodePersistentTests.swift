/// 文件说明：ClaudeCodePersistentTests，验证 Claude Code 持久进程模式（stream-json stdin/stdout）的集成测试。

@testable import ConchTalk
@preconcurrency import Citadel
import Foundation
import NIOCore
import NIOFoundationCompat
import NIOSSH
import Testing

/// ClaudeCodePersistentTests：
/// 验证持久进程架构：通过 SSH exec channel 启动 `claude -p --output-format stream-json --input-format stream-json --verbose`，
/// 进程保持运行，通过 stdin 发送 JSON prompt，从 stdout 读取 NDJSON 响应。
/// 1. 启动进程 + 立即发送 /cost prompt → 收到 system.init + result
/// 2. 在已启动的进程中发送第二个 prompt → 收到 assistant + result
/// 3. 多轮上下文验证：进程保持上下文，能回忆之前的对话
@Suite(.tags(.integration), .serialized)
struct ClaudeCodePersistentTests {

    // MARK: - 辅助方法

    /// 创建独立的 SSH 连接，执行闭包后同步断开。
    private func withSSHConnection<T: Sendable>(
        _ body: @Sendable (SSHClient) async throws -> T
    ) async throws -> T {
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

    /// 构建 ClaudeCodeUserMessage 的 JSON 字符串。
    nonisolated private static func makePromptJSON(text: String, sessionId: String = "") -> String {
        let msg = ClaudeCodeUserMessage(text: text, sessionId: sessionId)
        let data = try! JSONEncoder().encode(msg)
        return String(data: data, encoding: .utf8)!
    }

    /// 从 stdout 累积文本中提取所有完整的 JSON 行，解析为 ClaudeCodeMessage。
    nonisolated private static func parseMessages(from stdout: String) -> [(line: String, message: ClaudeCodeMessage)] {
        var results: [(String, ClaudeCodeMessage)] = []
        for line in stdout.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\r", with: "")
            guard trimmed.hasPrefix("{"),
                  let data = trimmed.data(using: .utf8),
                  let msg = try? JSONDecoder().decode(ClaudeCodeMessage.self, from: data)
            else { continue }
            results.append((trimmed, msg))
        }
        return results
    }

    /// 从消息列表中提取 session_id（从 system.init 消息）。
    nonisolated private static func extractSessionId(from messages: [(line: String, message: ClaudeCodeMessage)]) -> String? {
        for (_, msg) in messages {
            if case .system(let init_msg) = msg, init_msg.isInit {
                return init_msg.sessionId
            }
        }
        return nil
    }

    /// 从消息列表中提取 assistant 文本内容。
    nonisolated private static func extractAssistantText(from messages: [(line: String, message: ClaudeCodeMessage)]) -> String {
        var texts: [String] = []
        for (_, msg) in messages {
            if case .assistant(let assistantMsg) = msg {
                for block in assistantMsg.message.content {
                    if case .text(let text) = block {
                        texts.append(text)
                    }
                }
            }
        }
        return texts.joined(separator: " ")
    }

    /// 持久进程的 shell 启动命令（与 SSHProcessTransport 一致）。
    private var persistentCommand: String {
        let cwd = "/home/sel-pos-eye"
        let claudeFlags = "-p --output-format stream-json --input-format stream-json --verbose"
        return SSHSessionManager.shellInitPrefix
            + "exec sh -c 'cd \"\(cwd)\" && exec claude \(claudeFlags)'"
    }

    /// 信号错误，用于从 withTTY 闭包中跳出。
    private struct DoneSignal: Error {}

    // MARK: - Test 1: 启动持久进程 + 立即发送 /cost prompt

    /// 验证持久进程架构的核心流程：
    /// 1. 通过 TTY exec channel 发送 shell 启动命令
    /// 2. 立即写入 /cost JSON prompt 到 stdin
    /// 3. 从 stdout 读取 system.init 消息
    /// 4. 读取 result 消息（/cost 的响应）
    @Test(.timeLimit(.minutes(3)))
    func persistentProcessInitWithCost() async throws {
        _ = try await withSSHConnection { client in
            nonisolated(unsafe) var stdoutChunks: [String] = []
            nonisolated(unsafe) var stderrChunks: [String] = []
            nonisolated(unsafe) var gotResult = false

            let command = persistentCommand
            let promptJSON = Self.makePromptJSON(text: "/cost")

            print("[Test] === Test 1: Persistent process + /cost ===")
            print("[Test] Command: \(command.prefix(200))")
            print("[Test] Prompt JSON: \(promptJSON)")

            do {
                try await client.withTTY { inbound, outbound in
                    // 1. 发送 shell 启动命令
                    try await outbound.write(ByteBuffer(string: "\(command)\n"))
                    print("[Test] Shell command sent")

                    // 2. 立即写入 prompt JSON（不等待 system.init）
                    try await outbound.write(ByteBuffer(string: "\(promptJSON)\n"))
                    print("[Test] Prompt JSON sent immediately after command")

                    // 3. 读取 stdout，等待 system.init + result
                    readLoop: for try await chunk in inbound {
                        switch chunk {
                        case .stdout(let buf):
                            let text = String(data: Data(buffer: buf), encoding: .utf8) ?? ""
                            print("[Test] STDOUT (\(text.count) bytes): \(text.prefix(500))")
                            stdoutChunks.append(text)

                            // 检测到 result 消息，标记完成并跳出循环
                            if text.contains("\"type\":\"result\"") {
                                gotResult = true
                                // 等待缓冲区刷新
                                try await Task.sleep(for: .milliseconds(500))
                                break readLoop
                            }
                        case .stderr(let buf):
                            let text = String(data: Data(buffer: buf), encoding: .utf8) ?? ""
                            if !text.isEmpty {
                                print("[Test] STDERR: \(text.prefix(300))")
                                stderrChunks.append(text)
                            }
                        }
                    }
                    // 发送终止信号
                    try await outbound.write(ByteBuffer(string: "\u{03}\u{04}"))
                    // 抛出 DoneSignal 来退出 withTTY 闭包
                    throw DoneSignal()
                }
            } catch is DoneSignal {
                // 正常完成
                print("[Test] DoneSignal caught - test completed successfully")
            } catch {
                print("[Test] TTY channel closed: \(error)")
            }

            let totalStdout = stdoutChunks.joined()
            let totalStderr = stderrChunks.joined()
            let messages = Self.parseMessages(from: totalStdout)
            let sessionId = Self.extractSessionId(from: messages)

            print("[Test] === DIAGNOSTIC ===")
            print("[Test] Stdout total: \(totalStdout.count) bytes")
            print("[Test] Stderr total: \(totalStderr.count) bytes")
            print("[Test] Parsed messages: \(messages.count)")
            print("[Test] Session ID: \(sessionId ?? "nil")")
            print("[Test] Got result: \(gotResult)")

            for (i, (line, msg)) in messages.enumerated() {
                switch msg {
                case .system(let s):
                    print("[Test] Message[\(i)]: system (subtype=\(s.subtype ?? "nil"))")
                case .result(let r):
                    print("[Test] Message[\(i)]: result (subtype=\(r.subtype), cost=\(r.totalCostUsd ?? -1))")
                case .assistant:
                    print("[Test] Message[\(i)]: assistant")
                case .keepAlive:
                    print("[Test] Message[\(i)]: keepAlive/unknown")
                default:
                    print("[Test] Message[\(i)]: other - \(line.prefix(100))")
                }
            }

            // 验证
            let hasSystemInit = messages.contains { _, msg in
                if case .system(let s) = msg { return s.isInit }
                return false
            }
            let hasResult = messages.contains { _, msg in
                if case .result = msg { return true }
                return false
            }

            #expect(hasSystemInit, "Should receive system.init message from persistent process")
            #expect(hasResult, "Should receive result message for /cost prompt")
            #expect(sessionId != nil && !sessionId!.isEmpty, "Should have a valid session_id")

            return true
        }
    }

    // MARK: - Test 2: 持久进程中发送第二个 prompt

    /// 在持久进程中：
    /// 1. 发送 /cost 获取 system.init + result
    /// 2. 等待第一轮完成
    /// 3. 发送第二个 prompt "Say exactly: persistent-test"
    /// 4. 验证收到 assistant 消息包含 "persistent-test"
    @Test(.timeLimit(.minutes(5)))
    func persistentProcessSecondPrompt() async throws {
        _ = try await withSSHConnection { client in
            nonisolated(unsafe) var stdoutChunks: [String] = []
            nonisolated(unsafe) var stderrChunks: [String] = []
            nonisolated(unsafe) var firstResultSeen = false
            nonisolated(unsafe) var secondResultSeen = false
            nonisolated(unsafe) var secondPromptSent = false

            let command = persistentCommand
            let costPromptJSON = Self.makePromptJSON(text: "/cost")

            print("[Test] === Test 2: Persistent process second prompt ===")

            do {
                try await client.withTTY { inbound, outbound in
                    // 1. 启动进程 + 立即发送 /cost
                    try await outbound.write(ByteBuffer(string: "\(command)\n"))
                    try await outbound.write(ByteBuffer(string: "\(costPromptJSON)\n"))
                    print("[Test] Command + /cost sent")

                    // 2. 读取输出
                    readLoop: for try await chunk in inbound {
                        switch chunk {
                        case .stdout(let buf):
                            let text = String(data: Data(buffer: buf), encoding: .utf8) ?? ""
                            print("[Test] STDOUT (\(text.count) bytes): \(text.prefix(500))")
                            stdoutChunks.append(text)

                            // 检测第一个 result（/cost 的响应）
                            if !firstResultSeen && text.contains("\"type\":\"result\"") {
                                firstResultSeen = true
                                print("[Test] First result seen, sending second prompt...")

                                // 从已收到的输出中提取 sessionId
                                let allStdout = stdoutChunks.joined()
                                let msgs = Self.parseMessages(from: allStdout)
                                let sid = Self.extractSessionId(from: msgs) ?? ""
                                print("[Test] Using session_id for second prompt: \(sid)")

                                // 3. 发送第二个 prompt
                                let secondPromptJSON = Self.makePromptJSON(
                                    text: "Say exactly: persistent-test",
                                    sessionId: sid
                                )
                                try await Task.sleep(for: .milliseconds(500))
                                try await outbound.write(ByteBuffer(string: "\(secondPromptJSON)\n"))
                                secondPromptSent = true
                                print("[Test] Second prompt sent: \(secondPromptJSON.prefix(200))")
                            }

                            // 检测第二个 result
                            if firstResultSeen && secondPromptSent {
                                let allStdout = stdoutChunks.joined()
                                let resultCount = allStdout.components(separatedBy: "\"type\":\"result\"").count - 1
                                if resultCount >= 2 {
                                    secondResultSeen = true
                                    print("[Test] Second result seen!")
                                    try await Task.sleep(for: .milliseconds(500))
                                    break readLoop
                                }
                            }

                        case .stderr(let buf):
                            let text = String(data: Data(buffer: buf), encoding: .utf8) ?? ""
                            if !text.isEmpty {
                                print("[Test] STDERR: \(text.prefix(300))")
                                stderrChunks.append(text)
                            }
                        }
                    }
                    // 发送终止信号并退出
                    try await outbound.write(ByteBuffer(string: "\u{03}\u{04}"))
                    throw DoneSignal()
                }
            } catch is DoneSignal {
                print("[Test] DoneSignal caught - test completed successfully")
            } catch {
                print("[Test] TTY channel closed: \(error)")
            }

            let totalStdout = stdoutChunks.joined()
            let messages = Self.parseMessages(from: totalStdout)

            print("[Test] === DIAGNOSTIC ===")
            print("[Test] Total messages parsed: \(messages.count)")
            print("[Test] First result seen: \(firstResultSeen)")
            print("[Test] Second prompt sent: \(secondPromptSent)")
            print("[Test] Second result seen: \(secondResultSeen)")

            for (i, (_, msg)) in messages.enumerated() {
                switch msg {
                case .system(let s):
                    print("[Test] Message[\(i)]: system (subtype=\(s.subtype ?? "nil"))")
                case .result(let r):
                    print("[Test] Message[\(i)]: result (subtype=\(r.subtype), cost=\(r.totalCostUsd ?? -1))")
                case .assistant(let a):
                    let text = a.message.content.compactMap { block -> String? in
                        if case .text(let t) = block { return t }
                        return nil
                    }.joined()
                    print("[Test] Message[\(i)]: assistant text=\(text.prefix(200))")
                default:
                    print("[Test] Message[\(i)]: other")
                }
            }

            // 验证
            let assistantText = Self.extractAssistantText(from: messages)
            print("[Test] All assistant text: \(assistantText.prefix(500))")

            #expect(firstResultSeen, "Should receive result for /cost")
            #expect(secondPromptSent, "Should have sent second prompt")
            #expect(secondResultSeen, "Should receive result for second prompt")
            #expect(assistantText.lowercased().contains("persistent-test"),
                    "Assistant should say 'persistent-test', got: \(assistantText.prefix(300))")

            return true
        }
    }

    // MARK: - Test 3: 多轮上下文保持验证

    /// 在持久进程中验证多轮上下文：
    /// 1. /cost → system.init + result
    /// 2. "Say exactly: persistent-test" → assistant + result
    /// 3. "What did I just ask you?" → assistant 应引用之前的 prompt
    @Test(.timeLimit(.minutes(8)))
    func persistentProcessMultiTurnContext() async throws {
        _ = try await withSSHConnection { client in
            nonisolated(unsafe) var stdoutChunks: [String] = []
            nonisolated(unsafe) var stderrChunks: [String] = []
            nonisolated(unsafe) var resultCount = 0
            nonisolated(unsafe) var currentPhase = 1 // 1=等待cost result, 2=等待second result, 3=等待third result
            nonisolated(unsafe) var sessionId = ""
            let command = persistentCommand
            let costPromptJSON = Self.makePromptJSON(text: "/cost")

            print("[Test] === Test 3: Multi-turn context ===")

            do {
                try await client.withTTY { inbound, outbound in
                    // Phase 1: 启动 + /cost
                    try await outbound.write(ByteBuffer(string: "\(command)\n"))
                    try await outbound.write(ByteBuffer(string: "\(costPromptJSON)\n"))
                    print("[Test] Phase 1: Command + /cost sent")

                    readLoop: for try await chunk in inbound {
                        switch chunk {
                        case .stdout(let buf):
                            let text = String(data: Data(buffer: buf), encoding: .utf8) ?? ""
                            print("[Test] STDOUT (\(text.count) bytes, phase=\(currentPhase)): \(text.prefix(300))")
                            stdoutChunks.append(text)

                            // 每次收到 result，推进阶段
                            if text.contains("\"type\":\"result\"") {
                                resultCount += 1
                                print("[Test] Result #\(resultCount) detected")

                                // 提取 sessionId
                                if sessionId.isEmpty {
                                    let allStdout = stdoutChunks.joined()
                                    let msgs = Self.parseMessages(from: allStdout)
                                    sessionId = Self.extractSessionId(from: msgs) ?? ""
                                    print("[Test] Extracted sessionId: \(sessionId)")
                                }

                                if currentPhase == 1 {
                                    // Phase 2: 发送 "Say exactly: persistent-test"
                                    currentPhase = 2
                                    try await Task.sleep(for: .milliseconds(500))
                                    let prompt2 = Self.makePromptJSON(
                                        text: "Say exactly: persistent-test",
                                        sessionId: sessionId
                                    )
                                    try await outbound.write(ByteBuffer(string: "\(prompt2)\n"))
                                    print("[Test] Phase 2: Second prompt sent")
                                } else if currentPhase == 2 && resultCount >= 2 {
                                    // Phase 3: 发送 "What did I just ask you?"
                                    currentPhase = 3
                                    try await Task.sleep(for: .milliseconds(500))
                                    let prompt3 = Self.makePromptJSON(
                                        text: "What did I just ask you?",
                                        sessionId: sessionId
                                    )
                                    try await outbound.write(ByteBuffer(string: "\(prompt3)\n"))
                                    print("[Test] Phase 3: Third prompt sent")
                                } else if currentPhase == 3 && resultCount >= 3 {
                                    // 所有阶段完成
                                    print("[Test] All 3 rounds complete!")
                                    try await Task.sleep(for: .milliseconds(500))
                                    break readLoop
                                }
                            }

                        case .stderr(let buf):
                            let text = String(data: Data(buffer: buf), encoding: .utf8) ?? ""
                            if !text.isEmpty {
                                print("[Test] STDERR: \(text.prefix(300))")
                                stderrChunks.append(text)
                            }
                        }
                    }
                    // 发送终止信号并退出
                    try await outbound.write(ByteBuffer(string: "\u{03}\u{04}"))
                    throw DoneSignal()
                }
            } catch is DoneSignal {
                print("[Test] DoneSignal caught - test completed successfully")
            } catch {
                print("[Test] TTY channel closed: \(error)")
            }

            let totalStdout = stdoutChunks.joined()
            let messages = Self.parseMessages(from: totalStdout)

            print("[Test] === DIAGNOSTIC ===")
            print("[Test] Total messages: \(messages.count)")
            print("[Test] Result count: \(resultCount)")
            print("[Test] Final phase: \(currentPhase)")

            for (i, (_, msg)) in messages.enumerated() {
                switch msg {
                case .system(let s):
                    print("[Test] Message[\(i)]: system (subtype=\(s.subtype ?? "nil"))")
                case .result(let r):
                    print("[Test] Message[\(i)]: result (subtype=\(r.subtype), cost=\(r.totalCostUsd ?? -1))")
                case .assistant(let a):
                    let text = a.message.content.compactMap { block -> String? in
                        if case .text(let t) = block { return t }
                        return nil
                    }.joined()
                    print("[Test] Message[\(i)]: assistant text=\(text.prefix(200))")
                default:
                    print("[Test] Message[\(i)]: other")
                }
            }

            // 提取第三轮的 assistant 文本（在第二个 result 之后的 assistant 消息）
            var resultsSeen = 0
            var thirdRoundText = ""
            for (_, msg) in messages {
                if case .result = msg {
                    resultsSeen += 1
                }
                if resultsSeen >= 2, case .assistant(let a) = msg {
                    for block in a.message.content {
                        if case .text(let t) = block {
                            thirdRoundText += t + " "
                        }
                    }
                }
            }

            print("[Test] Third round assistant text: \(thirdRoundText.prefix(500))")

            // 验证
            #expect(resultCount >= 3, "Should have 3 results (cost + prompt + context check), got \(resultCount)")

            // 第三轮应该引用之前的对话内容（"persistent-test" 或 "say exactly"）
            let thirdLower = thirdRoundText.lowercased()
            let hasContextReference = thirdLower.contains("persistent") ||
                thirdLower.contains("say exactly") ||
                thirdLower.contains("persistent-test")
            #expect(hasContextReference,
                    "Third round should reference previous context, got: \(thirdRoundText.prefix(300))")

            return true
        }
    }
}
