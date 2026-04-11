/// 文件说明：ChatViewModelTaskFlowTests，覆盖发送与停止生成的基本状态流。
import Testing
@testable import ConchTalk
import Foundation
@preconcurrency import ACPModel

@Suite("ChatViewModel Task Flow")
@MainActor
struct ChatViewModelTaskFlowTests {
    @Test("navigation title and direct presentation derive from coordinator state")
    func navigationTitleAndDirectPresentation_followCoordinatorState() async throws {
        let store = try ChatViewModelTestSupport.makeInMemoryStore()
        let server = TestFixtures.makeServer(name: "Tokyo", host: "1.2.3.4")
        try await store.saveServer(server)

        let viewModel = ChatViewModelTestSupport.makeViewModel(server: server, store: store)
        #expect(viewModel.navigationTitle == "Tokyo")
        #expect(viewModel.directModePresentation.modeState == .inactive)

        // 通过 coordinator 连接 agent 以改变展示状态
        let factory: DirectSessionCoordinator.SessionFactory = makeCoordinatorSessionFactory(
            [.success(displayName: "Codex")],
            probes: SessionProbePool()
        )
        let coordinator = DirectSessionCoordinator(sessionFactory: factory)
        viewModel.directSessionCoordinator = coordinator
        let agent = AgentInfo(type: .codex, path: "/usr/bin/codex", version: nil)
        await coordinator.connect(agent: agent, cwd: "/tmp/work")

        #expect(viewModel.navigationTitle == "Codex")
        #expect(viewModel.directModePresentation.agent == .init(name: "Codex", type: .codex))
        #expect(viewModel.directModePresentation.inputBar.mode == .direct)
    }

    @Test("sendMessage 在空输入且无附件时不追加消息")
    func sendMessage_emptyInputAndNoAttachments_noOp() async throws {
        let store = try ChatViewModelTestSupport.makeInMemoryStore()
        let server = TestFixtures.makeServer()
        try await store.saveServer(server)

        let viewModel = ChatViewModelTestSupport.makeViewModel(server: server, store: store)
        let originalMessageCount = viewModel.messages.count

        viewModel.sendMessage()

        #expect(viewModel.messages.count == originalMessageCount)
        #expect(viewModel.isProcessing == false)
    }

    @Test("sendMessage 在普通模式会立即追加用户消息和 loading 消息")
    func sendMessage_normalModeAppendsUserAndLoadingMessage() async throws {
        let store = try ChatViewModelTestSupport.makeInMemoryStore()
        let server = TestFixtures.makeServer()
        try await store.saveServer(server)

        let viewModel = ChatViewModelTestSupport.makeViewModel(server: server, store: store)
        viewModel.inputText = "hello"

        viewModel.sendMessage()

        #expect(viewModel.messages.count == 2)
        #expect(viewModel.messages.first?.role == .user)
        #expect(viewModel.messages.first?.content == "hello")
        #expect(viewModel.messages.last?.isLoading == true)
        #expect(viewModel.isProcessing == true)
    }

    @Test("sendMessage 在直连模式发送后清空输入框")
    func sendMessage_directModeClearsInputText() async throws {
        let store = try ChatViewModelTestSupport.makeInMemoryStore()
        let server = TestFixtures.makeServer()
        try await store.saveServer(server)

        let factory: DirectSessionCoordinator.SessionFactory = makeCoordinatorSessionFactory(
            [.success(displayName: "OpenCode", promptBehavior: .waitForDisconnect)],
            probes: SessionProbePool()
        )
        let coordinator = DirectSessionCoordinator(sessionFactory: factory)

        let viewModel = ChatViewModelTestSupport.makeViewModel(server: server, store: store)
        viewModel.directSessionCoordinator = coordinator

        let agent = AgentInfo(type: .opencode, path: "/usr/bin/opencode", version: nil)
        await coordinator.connect(agent: agent, cwd: "/tmp/work")

        viewModel.inputText = "What can u help me"
        viewModel.sendMessage()

        #expect(viewModel.inputText.isEmpty)
    }

    @Test("clearTransientStreamingState + clearPendingInteractionState 会清理瞬时状态")
    func clearState_clearsTransientStreamingAndPendingState() async throws {
        let store = try ChatViewModelTestSupport.makeInMemoryStore()
        let server = TestFixtures.makeServer()
        try await store.saveServer(server)

        let viewModel = ChatViewModelTestSupport.makeViewModel(server: server, store: store)
        viewModel.isProcessing = true
        viewModel.showConfirmation = true
        viewModel.pendingToolCall = TestFixtures.makeToolCall()
        viewModel.isStreaming = true
        viewModel.isReasoningActive = true
        viewModel.activeReasoningText = "thinking"
        viewModel.activeContentText = "typing"
        viewModel.liveToolOutput = "tool"
        viewModel.agentStreamEvents = [.text("delta")]
        viewModel.isAgentExecuting = true
        viewModel.messages = [
            TestFixtures.makeMessage(role: .assistant, content: "", isLoading: true)
        ]

        viewModel.removeLoadingMessages()
        viewModel.clearPendingInteractionState()
        viewModel.clearTransientStreamingState()
        viewModel.isProcessing = false

        #expect(viewModel.messages.isEmpty)
        #expect(viewModel.showConfirmation == false)
        #expect(viewModel.pendingToolCall == nil)
        #expect(viewModel.isStreaming == false)
        #expect(viewModel.isReasoningActive == false)
        #expect(viewModel.activeReasoningText.isEmpty)
        #expect(viewModel.activeContentText.isEmpty)
        #expect(viewModel.liveToolOutput == nil)
        #expect(viewModel.agentStreamEvents.isEmpty)
        #expect(viewModel.isAgentExecuting == false)
        #expect(viewModel.isProcessing == false)
    }

    @Test("presentConfirmation 设置审批状态")
    func presentConfirmation_setsState() async throws {
        let store = try ChatViewModelTestSupport.makeInMemoryStore()
        let server = TestFixtures.makeServer()
        try await store.saveServer(server)

        let viewModel = ChatViewModelTestSupport.makeViewModel(server: server, store: store)
        let toolCall = TestFixtures.makeToolCall()

        viewModel.presentConfirmation(toolCall)
        #expect(viewModel.showConfirmation == true)
        #expect(viewModel.pendingToolCall?.id == toolCall.id)
    }

    @Test("loadMessages 恢复孤立直连状态时写入隐藏 AI context")
    func loadMessages_orphanedDirectModeRecoveryUsesHiddenAIContext() async throws {
        let store = try ChatViewModelTestSupport.makeInMemoryStore()
        let server = TestFixtures.makeServer()
        try await store.saveServer(server)

        let pausedToolCall = ToolCall(
            id: "tool-1",
            toolName: "suggest_agent_connection",
            argumentsJSON: Data("{}".utf8),
            explanation: "Connect to Codex"
        )
        let entry = Message(
            role: .command,
            content: "Session paused",
            toolCall: pausedToolCall,
            toolOutput: "Session paused",
            systemMessageType: nil
        )
        try await store.addMessage(entry, toServer: server.id)

        let viewModel = ChatViewModelTestSupport.makeViewModel(server: server, store: store)
        await viewModel.loadMessages()

        let aiContextMessages = viewModel.messages.filter { $0.systemMessageType == .aiContext }
        #expect(aiContextMessages.count == 1)
        #expect(aiContextMessages[0].content.contains("Previous direct agent session was interrupted"))
    }
}
