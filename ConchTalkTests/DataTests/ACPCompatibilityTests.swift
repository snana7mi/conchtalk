/// 文件说明：ACPCompatibilityTests，覆盖 ACP 协议参数兼容与连接重试策略。
import Testing
@testable import ConchTalk
import Foundation

@Suite("ACP Compatibility")
struct ACPCompatibilityTests {
    private enum RetryTestError: Error {
        case transient
    }

    private struct MessageError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private actor AttemptCounter {
        private var count: Int = 0

        func next() -> Int {
            count += 1
            return count
        }

        func current() -> Int {
            count
        }
    }

    private actor RetryHookCounter {
        private var count: Int = 0

        func bump() {
            count += 1
        }

        func current() -> Int {
            count
        }
    }

    @Test("session/new 默认携带空 mcpServers 数组")
    func sessionNewPayloadIncludesEmptyMCPServers() throws {
        let payload = SessionNewRequestPayload(cwd: "/root")
        let data = try JSONEncoder().encode(payload)
        let json = try JSONSerialization.jsonObject(with: data)

        guard let object = json as? [String: Any] else {
            #expect(Bool(false), "payload 应编码为 JSON object")
            return
        }

        #expect(object["cwd"] as? String == "/root")

        guard let mcpServers = object["mcpServers"] as? [Any] else {
            #expect(Bool(false), "payload 必须包含 mcpServers 字段")
            return
        }

        #expect(mcpServers.isEmpty)
    }

    @Test("openclaw 连接会对瞬时失败进行重试")
    func openclawConnectRetriesTransientFailure() async throws {
        let counter = AttemptCounter()

        let result: Int = try await DirectAgentSession.executeConnectWithRetry(
            agentType: .openclaw,
            sleep: { _ in }
        ) {
            let attempt = await counter.next()
            if attempt < 3 {
                throw RetryTestError.transient
            }
            return attempt
        }

        #expect(result == 3)
        let attempts = await counter.current()
        #expect(attempts == 3)
    }

    @Test("openclaw 重试前会执行预热回调")
    func openclawRetryInvokesHook() async throws {
        let counter = AttemptCounter()
        let hookCounter = RetryHookCounter()

        let result: Int = try await DirectAgentSession.executeConnectWithRetry(
            agentType: .openclaw,
            sleep: { _ in },
            onRetry: { _, _, _ in
                await hookCounter.bump()
            }
        ) {
            let attempt = await counter.next()
            if attempt < 3 {
                throw RetryTestError.transient
            }
            return attempt
        }

        #expect(result == 3)
        let hookCalls = await hookCounter.current()
        #expect(hookCalls == 2)
    }

    @Test("openclaw 提供 reset 与非 reset 两种 ACP 命令候选")
    func openclawCommandCandidatesIncludeFallback() {
        let info = AgentInfo(type: .openclaw, path: "/usr/bin/openclaw", version: nil)
        let commands = DirectAgentSession.acpCommandCandidates(for: info)

        #expect(commands.count == 2)
        #expect(commands[0].contains("--reset-session"))
        #expect(commands[1].contains("--session agent:main:main"))
        #expect(commands[1].contains("--reset-session") == false)
    }

    @Test("openclaw 的 gateway closed 失败使用短退避")
    func openclawGatewayClosedUsesShortBackoff() {
        let error = MessageError(message: "gateway connect failed: Error: gateway closed (1000):")
        let first = DirectAgentSession.retryDelayForAttempt(agentType: .openclaw, attempt: 1, error: error)
        let second = DirectAgentSession.retryDelayForAttempt(agentType: .openclaw, attempt: 2, error: error)
        #expect(first == .milliseconds(300))
        #expect(second == .milliseconds(600))
    }

    @Test("openclaw 的 challenge timeout 失败使用长退避")
    func openclawChallengeTimeoutUsesLongBackoff() {
        let error = MessageError(message: "Error: challenge timeout after 10000ms")
        let first = DirectAgentSession.retryDelayForAttempt(agentType: .openclaw, attempt: 1, error: error)
        let second = DirectAgentSession.retryDelayForAttempt(agentType: .openclaw, attempt: 2, error: error)
        #expect(first == .seconds(2))
        #expect(second == .seconds(4))
    }

    @Test("非 openclaw 仅保留单一 ACP 命令候选")
    func nonOpenclawCommandCandidatesSingle() {
        let info = AgentInfo(type: .qwen, path: "/usr/bin/qwen", version: nil)
        let commands = DirectAgentSession.acpCommandCandidates(for: info)

        #expect(commands == ["/usr/bin/qwen --acp"])
    }

    @Test("非 openclaw 连接失败时不做额外重试")
    func nonOpenclawConnectDoesNotRetry() async {
        let counter = AttemptCounter()
        let hookCounter = RetryHookCounter()

        await #expect(throws: RetryTestError.self) {
            try await DirectAgentSession.executeConnectWithRetry(
                agentType: .qwen,
                sleep: { _ in },
                onRetry: { _, _, _ in
                    await hookCounter.bump()
                }
            ) {
                _ = await counter.next()
                throw RetryTestError.transient
            }
        }

        let attempts = await counter.current()
        #expect(attempts == 1)
        let hookCalls = await hookCounter.current()
        #expect(hookCalls == 0)
    }
}
