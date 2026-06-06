/// 文件说明：SubagentRunnerTests，验证子 agent 编排：结果回填、并发上限、失败隔离、嵌套防护，及 DispatchSubagentTool 元信息。
import Testing
@testable import ConchTalk
import Foundation

@Suite("SubagentRunner")
struct SubagentRunnerTests {

    private func makeRunner(
        aiService: MockAIService,
        baseTools: [ToolProtocol],
        registry: SubagentRegistry,
        maxConcurrent: Int = 2
    ) -> SubagentRunner {
        let base = ToolRegistry(tools: baseTools)
        return SubagentRunner(
            aiService: aiService,
            sshClient: MockSSHClient(),
            baseToolRegistry: base,
            registry: registry,
            serverID: nil,
            permissionLevel: .standard,
            serverContext: "ctx",
            approvalGate: SubagentApprovalGate(),
            parentConfirm: { _ in .denied },
            maxConcurrent: maxConcurrent
        )
    }

    private func def(_ name: String, tools: [String] = []) -> SubagentDefinition {
        SubagentDefinition(name: name, description: "d", allowedTools: tools, metadata: [:], systemPrompt: "you are \(name)")
    }

    @Test("子 agent 文本结论被回填")
    func outcomeReturned() async {
        let ai = MockAIService()
        ai.streamingResponses = [[.content("explored: found auth in auth.swift"), .done]]
        let registry = SubagentRegistry(preloaded: [def("explorer")])
        let runner = makeRunner(aiService: ai, baseTools: [], registry: registry)

        let results = await runner.run(tasks: [SubagentTask(subagentType: "explorer", prompt: "find auth")])
        #expect(results.count == 1)
        #expect(results[0].succeeded)
        #expect(results[0].outcome == "explored: found auth in auth.swift")
        #expect(results[0].subagentName == "explorer")
    }

    @Test("未知角色返回失败结果，不抛错")
    func unknownRole() async {
        let ai = MockAIService()
        let registry = SubagentRegistry(preloaded: [])
        let runner = makeRunner(aiService: ai, baseTools: [], registry: registry)

        let results = await runner.run(tasks: [SubagentTask(subagentType: "ghost", prompt: "do")])
        #expect(results.count == 1)
        #expect(results[0].succeeded == false)
        #expect(results[0].errorSummary?.contains("ghost") ?? false)
    }

    @Test("受限工具表：白名单过滤且永远剔除 dispatch_subagent")
    func restrictedTools() async {
        let ai = MockAIService()
        let registry = SubagentRegistry(preloaded: [def("explorer", tools: ["read_file"])])
        let base: [ToolProtocol] = [
            MockTool(name: "read_file"),
            MockTool(name: "write_file"),
            MockTool(name: "dispatch_subagent")
        ]
        let runner = makeRunner(aiService: ai, baseTools: base, registry: registry)

        let registryForRole = runner.makeRestrictedRegistry(for: def("explorer", tools: ["read_file"]))
        #expect(registryForRole.tool(named: "read_file") != nil)
        #expect(registryForRole.tool(named: "write_file") == nil)
        #expect(registryForRole.tool(named: "dispatch_subagent") == nil)
    }

    @Test("空白名单继承父工具，但仍剔除 dispatch_subagent")
    func emptyWhitelistInherits() async {
        let ai = MockAIService()
        let registry = SubagentRegistry(preloaded: [def("general-purpose")])
        let base: [ToolProtocol] = [MockTool(name: "read_file"), MockTool(name: "dispatch_subagent")]
        let runner = makeRunner(aiService: ai, baseTools: base, registry: registry)

        let restricted = runner.makeRestrictedRegistry(for: def("general-purpose"))
        #expect(restricted.tool(named: "read_file") != nil)
        #expect(restricted.tool(named: "dispatch_subagent") == nil)
    }

    @Test("多个任务全部返回结果（并发上限内）")
    func multipleTasks() async {
        let ai = MockAIService()
        ai.streamingResponses = [
            [.content("r1"), .done],
            [.content("r2"), .done],
            [.content("r3"), .done]
        ]
        let registry = SubagentRegistry(preloaded: [def("explorer")])
        let runner = makeRunner(aiService: ai, baseTools: [], registry: registry, maxConcurrent: 2)

        let tasks = (0..<3).map { SubagentTask(subagentType: "explorer", prompt: "t\($0)") }
        let results = await runner.run(tasks: tasks)
        #expect(results.count == 3)
        #expect(results.allSatisfy { $0.succeeded })
        // 保序保证：结果按输入任务顺序回填，不受并发完成顺序影响。
        #expect(results.map(\.task) == ["t0", "t1", "t2"])
    }

    @Test("并发中单个失败被隔离，其余成功")
    func mixedFailureIsolation() async {
        let ai = MockAIService()
        ai.streamingResponses = [[.content("ok"), .done], [.content("ok"), .done]]
        let registry = SubagentRegistry(preloaded: [def("explorer")])
        let runner = makeRunner(aiService: ai, baseTools: [], registry: registry, maxConcurrent: 2)
        let tasks = [
            SubagentTask(subagentType: "explorer", prompt: "ok1"),
            SubagentTask(subagentType: "ghost",    prompt: "boom"),
            SubagentTask(subagentType: "explorer", prompt: "ok2"),
        ]
        let results = await runner.run(tasks: tasks)
        #expect(results.filter { $0.succeeded }.count == 2)
        #expect(results.filter { !$0.succeeded }.count == 1)
    }

    @Test("并发上限被遵守：同时运行的子 agent 不超过 maxConcurrent")
    func respectsConcurrencyLimit() async {
        let detector = ConcurrencyOverlapDetector()
        let ai = ConcurrencyTrackingAIService(detector: detector)
        let registry = SubagentRegistry(preloaded: [def("explorer")])
        let runner = SubagentRunner(
            aiService: ai,
            sshClient: MockSSHClient(),
            baseToolRegistry: ToolRegistry(tools: []),
            registry: registry,
            serverID: nil,
            permissionLevel: .standard,
            serverContext: "ctx",
            approvalGate: SubagentApprovalGate(),
            parentConfirm: { _ in .denied },
            maxConcurrent: 2
        )

        let tasks = (0..<6).map { SubagentTask(subagentType: "explorer", prompt: "t\($0)") }
        let results = await runner.run(tasks: tasks)
        #expect(results.count == 6)

        let maxObserved = await detector.maxConcurrent
        // 限流不变式：任意时刻并发数不超过上限。
        #expect(maxObserved <= 2)
        // 上限内确有并行发生（否则说明退化为串行）。
        #expect(maxObserved >= 2)
    }

    @Test("空任务列表返回空")
    func emptyTasks() async {
        let runner = makeRunner(aiService: MockAIService(), baseTools: [], registry: SubagentRegistry(preloaded: []))
        let results = await runner.run(tasks: [])
        #expect(results.isEmpty)
    }
}

// MARK: - 并发测试辅助

/// ConcurrencyOverlapDetector：记录并发进入峰值，用于验证并发限流。
private actor ConcurrencyOverlapDetector {
    private(set) var maxConcurrent = 0
    private var current = 0

    func enter() {
        current += 1
        maxConcurrent = max(maxConcurrent, current)
    }

    func leave() {
        current -= 1
    }
}

/// ConcurrencyTrackingAIService：在每次流式调用进入/离开时记录并发数，并保持一小段重叠窗口。
private final class ConcurrencyTrackingAIService: AIServiceProtocol, @unchecked Sendable {
    private let detector: ConcurrencyOverlapDetector

    init(detector: ConcurrencyOverlapDetector) {
        self.detector = detector
    }

    func sendMessageStreaming(
        _ message: String,
        conversationHistory: [Message],
        serverContext: String,
        serverID: UUID?,
        permissionLevel: PermissionLevel,
        serverName: String,
        serverCapabilities: ServerCapabilities
    ) -> AsyncStream<StreamingDelta> {
        let detector = self.detector
        return AsyncStream { continuation in
            Task {
                await detector.enter()
                try? await Task.sleep(for: .milliseconds(40))
                await detector.leave()
                continuation.yield(.content("done"))
                continuation.yield(.done)
                continuation.finish()
            }
        }
    }

    func sendToolResultStreaming(
        _ result: String,
        forToolCall: ToolCall,
        conversationHistory: [Message],
        serverContext: String,
        serverID: UUID?,
        permissionLevel: PermissionLevel,
        serverName: String,
        serverCapabilities: ServerCapabilities
    ) -> AsyncStream<StreamingDelta> {
        AsyncStream { continuation in
            continuation.yield(.content("done"))
            continuation.yield(.done)
            continuation.finish()
        }
    }

    func generateMemorySummary(
        recentMessages: [Message],
        existingConversationMemory: String?,
        existingServerMemory: String?,
        existingGlobalMemory: String?
    ) async throws -> MemorySummaryResult {
        MemorySummaryResult(conversationMemory: nil, serverMemory: nil, globalMemory: nil)
    }

    func sendSimpleMessage(_ prompt: String) async throws -> String { "" }
}

@Suite("DispatchSubagentTool")
struct DispatchSubagentToolTests {
    @Test("名称与安全级别")
    func basics() {
        let tool = DispatchSubagentTool(subagentSummaries: "- explorer: explore")
        #expect(tool.name == "dispatch_subagent")
        #expect(tool.validateSafety(arguments: [:]) == .safe)
    }

    @Test("schema 含 tasks 数组与 subagent_type/prompt")
    func schema() {
        let tool = DispatchSubagentTool(subagentSummaries: "- explorer: explore")
        let schema = tool.parametersSchema
        let props = schema["properties"] as? [String: Any]
        let tasks = props?["tasks"] as? [String: Any]
        #expect(tasks != nil)

        let items = tasks?["items"] as? [String: Any]
        let itemProps = items?["properties"] as? [String: Any]
        #expect(itemProps?["subagent_type"] != nil)
        #expect(itemProps?["prompt"] != nil)

        let required = items?["required"] as? [String]
        #expect(required?.contains("subagent_type") ?? false)
        #expect(required?.contains("prompt") ?? false)
    }

    @Test("description 注入角色摘要")
    func descriptionHasSummaries() {
        let tool = DispatchSubagentTool(subagentSummaries: "- explorer: explore code")
        #expect(tool.description.contains("explorer"))
    }
}

@Suite("SubagentDispatchHandler")
struct SubagentDispatchHandlerTests {
    /// StubRunner：按固定结果应答的 SubagentRunning 打桩，便于隔离测试 handler 的解析与回填逻辑。
    private struct StubRunner: SubagentRunning {
        let results: [SubagentResult]
        func run(tasks: [SubagentTask]) async -> [SubagentResult] { results }
    }

    @Test("解析 tasks 并生成卡片消息与汇总输出")
    func handleBuildsMessagesAndOutput() async {
        let runner = StubRunner(results: [
            SubagentResult(subagentName: "explorer", task: "find auth", outcome: "auth in a.swift", succeeded: true, errorSummary: nil)
        ])
        let call = TestFixtures.makeToolCall(
            id: "d1",
            toolName: "dispatch_subagent",
            arguments: ["tasks": [["subagent_type": "explorer", "prompt": "find auth"]]]
        )
        let out = await SubagentDispatchHandler.handle(toolCall: call, reasoning: nil, runner: runner)
        #expect(out.messages.count == 1)
        #expect(out.messages[0].role == .command)
        #expect(out.messages[0].toolCall == nil)
        #expect(out.messages[0].toolOutput == "auth in a.swift")
        #expect(out.output.contains("explorer"))
        #expect(out.output.contains("auth in a.swift"))
    }

    @Test("空 tasks 返回错误输出")
    func handleEmptyTasks() async {
        let runner = StubRunner(results: [])
        let call = TestFixtures.makeToolCall(id: "d2", toolName: "dispatch_subagent", arguments: ["tasks": [] as [Any]])
        let out = await SubagentDispatchHandler.handle(toolCall: call, reasoning: nil, runner: runner)
        #expect(out.messages.isEmpty)
        #expect(out.output.contains("ERROR"))
    }

    @Test("失败结果在输出中标注失败")
    func handleFailure() async {
        let runner = StubRunner(results: [
            SubagentResult(subagentName: "ghost", task: "x", outcome: "", succeeded: false, errorSummary: "Unknown subagent type: ghost")
        ])
        let call = TestFixtures.makeToolCall(
            id: "d3", toolName: "dispatch_subagent",
            arguments: ["tasks": [["subagent_type": "ghost", "prompt": "x"]]]
        )
        let out = await SubagentDispatchHandler.handle(toolCall: call, reasoning: nil, runner: runner)
        #expect(out.output.contains("Unknown subagent type: ghost"))
    }
}
