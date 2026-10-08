/// 文件说明：PlanAndAskUserToolTests，验证 update_plan / ask_user 的参数解析、agentic loop 拦截、子 agent 剔除与 UI 辅助逻辑。
import Testing
@testable import ConchTalk
import Foundation

@Suite("update_plan / ask_user parsing")
struct PlanAndAskUserParsingTests {

    @Test("计划解析：合法步骤、说明裁剪、完成计数")
    func parsesPlan() throws {
        let result = AgentPlanUpdate.parse([
            "plan": [
                ["step": "Check nginx status", "status": "completed"],
                ["step": " Read error log ", "status": "in_progress"],
                ["step": "Fix config", "status": "pending"],
            ],
            "explanation": "  added fix step ",
        ])
        let update = try result.get()
        #expect(update.entries.map(\.title) == ["Check nginx status", "Read error log", "Fix config"])
        #expect(update.entries.map(\.status) == ["completed", "in_progress", "pending"])
        #expect(update.explanation == "added fix step")
        #expect(update.completedCount == 1)
        #expect(update.modelAcknowledgement.contains("1/3"))
    }

    @Test("计划解析：空计划、缺 step、非法状态均报错；超过上限截断")
    func rejectsInvalidPlans() {
        #expect((try? AgentPlanUpdate.parse([:]).get()) == nil)
        #expect((try? AgentPlanUpdate.parse(["plan": []]).get()) == nil)
        #expect((try? AgentPlanUpdate.parse(["plan": [["status": "pending"]]]).get()) == nil)
        #expect((try? AgentPlanUpdate.parse(["plan": [["step": "x", "status": "done"]]]).get()) == nil)
        let many = (0..<30).map { ["step": "s\($0)", "status": "pending"] }
        #expect((try? AgentPlanUpdate.parse(["plan": many]).get())?.entries.count == AgentPlanUpdate.maxSteps)
        // 缺省状态视为 pending
        #expect((try? AgentPlanUpdate.parse(["plan": [["step": "x"]]]).get())?.entries.first?.status == "pending")
    }

    @Test("问题解析：裁剪、去重、过滤空项与上限")
    func parsesQuestion() throws {
        let q = try #require(UserQuestion.parse([
            "question": " Which site? ",
            "options": ["blog", " blog ", "", "shop", 42, String(repeating: "x", count: 200)],
        ]))
        #expect(q.question == "Which site?")
        #expect(q.options == ["blog", "shop"])
        #expect(q.modelAcknowledgement.contains("\"blog\""))
        #expect(UserQuestion.parse(["question": "  "]) == nil)
        #expect(UserQuestion.parse(["question": "Open?"])?.options == [])
        let many = (0..<10).map { "o\($0)" }
        #expect(UserQuestion.parse(["question": "q", "options": many])?.options.count == UserQuestion.maxOptions)
    }

    @Test("从工具调用还原：仅匹配对应工具名")
    func fromToolCall() {
        let planCall = ToolCall(id: "p", toolName: "update_plan", argumentsJSON: Data(#"{"plan":[{"step":"a","status":"pending"}]}"#.utf8), explanation: "")
        #expect(AgentPlanUpdate.from(toolCall: planCall)?.entries.count == 1)
        #expect(UserQuestion.from(toolCall: planCall) == nil)
        let askCall = ToolCall(id: "q", toolName: "ask_user", argumentsJSON: Data(#"{"question":"Restart now?","options":["Yes","No"]}"#.utf8), explanation: "")
        #expect(UserQuestion.from(toolCall: askCall)?.options == ["Yes", "No"])
        #expect(AgentPlanUpdate.from(toolCall: askCall) == nil)
    }

    @Test("工具元信息：安全、必填字段，基础工具表包含两个新工具")
    func toolMetadata() {
        #expect(UpdatePlanTool().validateSafety(arguments: [:]) == .safe)
        #expect(AskUserTool().validateSafety(arguments: [:]) == .safe)
        #expect((UpdatePlanTool().parametersSchema["required"] as? [String]) == ["plan"])
        #expect((AskUserTool().parametersSchema["required"] as? [String]) == ["question"])
        let names = ToolRegistryFactory.makeBaseTools(skillRegistry: SkillRegistry(preloaded: []), keychainService: MockKeychainService()).map(\.name)
        #expect(names.contains("update_plan"))
        #expect(names.contains("ask_user"))
    }

    @Test("回复通知预览：以提问结束时显示问题")
    func notificationPreview() {
        let ask = ToolCall(id: "q", toolName: "ask_user", argumentsJSON: Data(#"{"question":"Which env?"}"#.utf8), explanation: "")
        let messages = [
            Message(role: .assistant, content: "Earlier text"),
            Message(role: .command, content: "Which env?", toolCall: ask, toolOutput: "shown"),
        ]
        #expect(TaskExecutionCoordinator.replyNotificationPreview(for: messages) == "Which env?")
        #expect(TaskExecutionCoordinator.replyNotificationPreview(for: [Message(role: .assistant, content: "Done")]) == "Done")
        #expect(TaskExecutionCoordinator.replyNotificationPreview(for: []) == nil)
    }
}

@Suite("update_plan / ask_user in agentic loop")
struct PlanAndAskUserLoopTests {

    private func makeUseCase(
        ai: MockAIService,
        registry: MockToolRegistry,
        permission: PermissionLevel = .strict
    ) -> ExecuteNaturalLanguageCommandUseCase {
        ExecuteNaturalLanguageCommandUseCase(
            aiService: ai,
            sshClient: MockSSHClient(),
            toolRegistry: registry,
            serverID: nil,
            permissionLevel: permission
        )
    }

    @Test("update_plan：严格模式下也不请求审批，落计划消息后继续循环")
    func planIsInterceptedWithoutApproval() async throws {
        let ai = MockAIService()
        let registry = MockToolRegistry()
        registry.register(UpdatePlanTool())
        let useCase = makeUseCase(ai: ai, registry: registry)
        let asked = LockedBox(false)
        useCase.onToolCallNeedsConfirmation = { _ in asked.set(true); return .denied }

        let call = ToolCall(id: "call_plan", toolName: "update_plan", argumentsJSON: Data(#"{"plan":[{"step":"Inspect","status":"in_progress"}]}"#.utf8), explanation: "")
        ai.streamingResponses = [
            [.toolCall(call), .done],
            [.content("Done."), .done],
        ]
        let messages = try await useCase.execute(userMessage: "fix nginx", conversationHistory: [], serverContext: "")

        #expect(!asked.value)
        #expect(messages.count == 2)
        #expect(messages[0].toolCall?.toolName == "update_plan")
        #expect(messages[0].toolOutput?.hasPrefix("Plan updated") == true)
        #expect(messages[1].content == "Done.")
    }

    @Test("ask_user：落问题消息并结束本轮，同一响应中后续调用不执行")
    func askUserEndsTurn() async throws {
        let ai = MockAIService()
        let registry = MockToolRegistry()
        registry.register(AskUserTool())
        let laterTool = MockTool(name: "execute_ssh_command", safetyLevel: .safe, executeResult: ToolExecutionResult(output: "ran"))
        registry.register(laterTool)
        let useCase = makeUseCase(ai: ai, registry: registry, permission: .standard)

        let ask = ToolCall(id: "call_ask", toolName: "ask_user", argumentsJSON: Data(#"{"question":"Which site?","options":["blog","shop"]}"#.utf8), explanation: "")
        let later = ToolCall(id: "call_later", toolName: "execute_ssh_command", argumentsJSON: Data(#"{"command":"ls"}"#.utf8), explanation: "")
        ai.streamingResponses = [
            [.toolCall(ask), .toolCall(later), .done],
        ]
        let messages = try await useCase.execute(userMessage: "restart the site", conversationHistory: [], serverContext: "")

        #expect(messages.count == 1)
        #expect(messages[0].role == .command)
        #expect(messages[0].content == "Which site?")
        #expect(messages[0].toolOutput?.contains("next message") == true)
        #expect(laterTool.executeCalled == 0)
        #expect(ai.callHistory.count == 1, "提问后不再请求模型")
    }

    @Test("ask_user 不在工具表中（如子 agent）时按未知工具处理")
    func askUserUnavailableFallsBack() async throws {
        let ai = MockAIService()
        let registry = MockToolRegistry()
        let useCase = makeUseCase(ai: ai, registry: registry, permission: .standard)
        let ask = ToolCall(id: "call_ask", toolName: "ask_user", argumentsJSON: Data(#"{"question":"Q?"}"#.utf8), explanation: "")
        ai.streamingResponses = [
            [.toolCall(ask), .done],
            [.content("Answering without asking."), .done],
        ]
        let messages = try await useCase.execute(userMessage: "x", conversationHistory: [], serverContext: "")
        #expect(messages.last?.content == "Answering without asking.")
        let history = try #require(ai.callHistory.last?.history)
        #expect(history.contains { $0.toolCall?.id == "call_ask" && $0.toolOutput?.contains("Unknown tool") == true })
    }

    @Test("子 agent 工具表剔除 ask_user / update_plan / dispatch_subagent")
    func subagentExcludesMainLoopTools() {
        let base = ToolRegistry(tools: [MockTool(name: "read_file"), AskUserTool(), UpdatePlanTool(), MockTool(name: "dispatch_subagent")])
        let runner = SubagentRunner(
            aiService: MockAIService(),
            sshClient: MockSSHClient(),
            baseToolRegistry: base,
            registry: SubagentRegistry(preloaded: []),
            serverID: nil,
            permissionLevel: .standard,
            serverContext: "",
            approvalGate: SubagentApprovalGate(),
            parentConfirm: { _ in .denied },
            maxConcurrent: 1
        )
        let restricted = runner.makeRestrictedRegistry(
            for: SubagentDefinition(name: "g", description: "d", allowedTools: [], metadata: [:], systemPrompt: "")
        )
        #expect(restricted.tool(named: "read_file") != nil)
        #expect(restricted.tool(named: "ask_user") == nil)
        #expect(restricted.tool(named: "update_plan") == nil)
        #expect(restricted.tool(named: "dispatch_subagent") == nil)
    }
}

@Suite("ask_user answering")
@MainActor
struct AskUserAnswerTests {

    @Test("仅最新的提问可回答；点选项作为用户消息发送")
    func answerableQuestion() async throws {
        let store = try ChatViewModelTestSupport.makeInMemoryStore()
        let server = TestFixtures.makeServer()
        try await store.saveServer(server)
        let viewModel = ChatViewModelTestSupport.makeViewModel(server: server, store: store)

        let ask = ToolCall(id: "q", toolName: "ask_user", argumentsJSON: Data(#"{"question":"Which?","options":["A","B"]}"#.utf8), explanation: "")
        let question = Message(role: .command, content: "Which?", toolCall: ask, toolOutput: "shown")
        viewModel.messages = [Message(role: .user, content: "do it"), question]
        #expect(viewModel.answerableQuestionMessageID == question.id)

        viewModel.isProcessing = true
        #expect(viewModel.answerableQuestionMessageID == nil)
        viewModel.isProcessing = false

        viewModel.messages.append(Message(role: .assistant, content: "later"))
        #expect(viewModel.answerableQuestionMessageID == nil)
        viewModel.answerQuestion("A")
        #expect(!viewModel.messages.contains { $0.role == .user && $0.content == "A" }, "过期问题不可回答")

        viewModel.messages.removeLast()
        viewModel.answerQuestion("B")
        #expect(viewModel.messages.contains { $0.role == .user && $0.content == "B" })
    }
}
