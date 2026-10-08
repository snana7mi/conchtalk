/// 文件说明：ParallelReadOnlyToolCallTests，验证同一响应中连续只读工具调用并行执行、结果顺序不变，写操作与审批保持串行。
import Foundation
import Testing
@testable import ConchTalk

/// 记录执行事件与并发度的探针。
actor ToolExecutionProbe {
    private(set) var events: [String] = []
    private var running = 0
    private(set) var maxRunning = 0

    func start(_ name: String) {
        events.append("start:\(name)")
        running += 1
        maxRunning = max(maxRunning, running)
    }

    func finish(_ name: String) {
        events.append("end:\(name)")
        running -= 1
    }

    func record(_ event: String) {
        events.append(event)
    }
}

/// 带延时的探针工具：按参数 `label` 记录执行。
nonisolated struct ProbeTool: ToolProtocol, @unchecked Sendable {
    let name: String
    let safety: SafetyLevel
    let probe: ToolExecutionProbe
    let delay: Duration
    let description = "probe"
    let parametersSchema: [String: Any] = ["type": "object"]

    func validateSafety(arguments: [String: Any]) -> SafetyLevel { safety }

    func execute(arguments: [String: Any], sshClient: SSHClientProtocol) async throws -> ToolExecutionResult {
        let label = arguments["label"] as? String ?? name
        await probe.start(label)
        try await Task.sleep(for: delay)
        await probe.finish(label)
        return ToolExecutionResult(output: "out-\(label)")
    }
}

@Suite("Parallel read-only tool calls")
struct ParallelReadOnlyToolCallTests {

    private func call(_ tool: String, _ label: String) -> ToolCall {
        ToolCall(id: "call_\(label)", toolName: tool, argumentsJSON: Data(#"{"label":"\#(label)"}"#.utf8), explanation: label, responseID: "msg_1")
    }

    @Test("连续只读调用并行执行，消息与回填顺序保持原样")
    func readOnlyCallsRunInParallel() async throws {
        let probe = ToolExecutionProbe()
        let ai = MockAIService()
        let registry = MockToolRegistry()
        registry.register(ProbeTool(name: "read_file", safety: .safe, probe: probe, delay: .milliseconds(200)))
        registry.register(ProbeTool(name: "grep", safety: .safe, probe: probe, delay: .milliseconds(200)))
        let useCase = ExecuteNaturalLanguageCommandUseCase(aiService: ai, sshClient: MockSSHClient(), toolRegistry: registry)

        ai.streamingResponses = [
            [.toolCall(call("read_file", "a")), .toolCall(call("grep", "b")), .toolCall(call("read_file", "c")), .done],
            [.content("summary"), .done],
        ]
        let clock = ContinuousClock()
        let start = clock.now
        let messages = try await useCase.execute(userMessage: "look", conversationHistory: [], serverContext: "")
        let elapsed = clock.now - start

        #expect(await probe.maxRunning == 3)
        #expect(elapsed < .milliseconds(550), "并行执行应明显快于串行 600ms")
        #expect(messages.map(\.toolOutput) == ["out-a", "out-b", "out-c", nil])
        #expect(messages.last?.content == "summary")
        #expect(ai.callHistory.count == 2, "三个结果回填后只请求一次模型")
    }

    @Test("写操作切断并行批次：其后的只读调用要等审批与写入完成后才执行")
    func writeSplitsRunAndKeepsApprovalOrder() async throws {
        let probe = ToolExecutionProbe()
        let ai = MockAIService()
        let registry = MockToolRegistry()
        registry.register(ProbeTool(name: "read_file", safety: .safe, probe: probe, delay: .milliseconds(50)))
        registry.register(ProbeTool(name: "write_file", safety: .needsConfirmation, probe: probe, delay: .milliseconds(50)))
        let useCase = ExecuteNaturalLanguageCommandUseCase(aiService: ai, sshClient: MockSSHClient(), toolRegistry: registry)
        useCase.onToolCallNeedsConfirmation = { request in
            await probe.record("approve:\(request.toolCall.explanation)")
            return .approvedOnce
        }

        ai.streamingResponses = [
            [.toolCall(call("read_file", "r1")), .toolCall(call("read_file", "r2")),
             .toolCall(call("write_file", "w")), .toolCall(call("read_file", "r3")), .done],
            [.content("ok"), .done],
        ]
        let messages = try await useCase.execute(userMessage: "edit", conversationHistory: [], serverContext: "")
        let events = await probe.events

        let approveIndex = try #require(events.firstIndex(of: "approve:w"))
        let writeEnd = try #require(events.firstIndex(of: "end:w"))
        let r3Start = try #require(events.firstIndex(of: "start:r3"))
        #expect(events.firstIndex(of: "end:r1")! < approveIndex)
        #expect(events.firstIndex(of: "end:r2")! < approveIndex)
        #expect(writeEnd < r3Start, "写之后的读不得提前执行")
        #expect(await probe.maxRunning == 2)
        #expect(messages.compactMap(\.toolOutput) == ["out-r1", "out-r2", "out-w", "out-r3"])
    }

    @Test("严格模式下不并行（每个调用都需确认）")
    func strictModeIsSerial() {
        let registry = MockToolRegistry()
        registry.register(MockTool(name: "read_file", safetyLevel: .safe))
        let strict = ExecuteNaturalLanguageCommandUseCase(aiService: MockAIService(), sshClient: MockSSHClient(), toolRegistry: registry, permissionLevel: .strict)
        let standard = ExecuteNaturalLanguageCommandUseCase(aiService: MockAIService(), sshClient: MockSSHClient(), toolRegistry: registry, permissionLevel: .standard)
        let readCall = call("read_file", "x")
        #expect(!strict.isParallelSafe(readCall))
        #expect(standard.isParallelSafe(readCall))
    }

    @Test("只有白名单只读工具且本次参数判定为 safe 时才可并行")
    func parallelEligibility() {
        let registry = MockToolRegistry()
        registry.register(MockTool(name: "execute_ssh_command", safetyLevel: .needsConfirmation))
        registry.register(MockTool(name: "custom_tool", safetyLevel: .safe))
        registry.register(MockTool(name: "glob", safetyLevel: .safe))
        let useCase = ExecuteNaturalLanguageCommandUseCase(aiService: MockAIService(), sshClient: MockSSHClient(), toolRegistry: registry)
        #expect(!useCase.isParallelSafe(call("execute_ssh_command", "rm")), "被判定为写的命令不并行")
        #expect(!useCase.isParallelSafe(call("custom_tool", "c")), "非白名单工具不并行")
        #expect(!useCase.isParallelSafe(call("ask_user", "q")))
        #expect(useCase.isParallelSafe(call("glob", "g")))
        var truncated = call("glob", "t")
        truncated.truncatedByMaxTokens = true
        #expect(!useCase.isParallelSafe(truncated))
    }
}
