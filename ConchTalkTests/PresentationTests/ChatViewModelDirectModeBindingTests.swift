/// 文件说明：ChatViewModelDirectModeBindingTests，验证 ChatViewModel 与 DirectSessionCoordinator 的绑定行为。
import Testing
@testable import ConchTalk
import Foundation
@preconcurrency import ACPModel

@Suite("ChatViewModel DirectMode Binding")
@MainActor
struct ChatViewModelDirectModeBindingTests {

    // MARK: - directModePresentation 派生测试

    @Test("directModePresentation idle 时为 inactive")
    func directModePresentation_idleIsInactive() async throws {
        let coordinator = DirectSessionCoordinator()
        let presentation = DirectModePresentationState.build(from: coordinator.state)

        #expect(presentation.modeState == .inactive)
        #expect(!presentation.isActive)
        #expect(presentation.agent == nil)
        #expect(presentation.statusBar.status == .inactive)
        #expect(presentation.inputBar.mode == .normal)
        #expect(!presentation.isExecuting)
        #expect(presentation.transition == .none)
    }

    @Test("directModePresentation connected 时为 active")
    func directModePresentation_connectedIsActive() async throws {
        let (coordinator, _) = makeCoordinator(outcomes: [
            .success(displayName: "Codex")
        ])
        let agent = AgentInfo(type: .codex, path: "/usr/bin/codex", version: nil)
        await coordinator.connect(agent: agent, cwd: "/tmp/work")

        let presentation = DirectModePresentationState.build(from: coordinator.state)

        #expect(presentation.modeState == .active)
        #expect(presentation.isActive)
        #expect(presentation.agent == .init(name: "Codex", type: .codex))
        #expect(presentation.statusBar.status == .connected)
        #expect(presentation.statusBar.marker == .direct)
        #expect(presentation.inputBar.mode == .direct)
        #expect(presentation.inputBar.isEnabled == true)
        #expect(presentation.inputBar.showsCancel == false)
        #expect(!presentation.isExecuting)
        #expect(presentation.transition == .none)
    }

    @Test("directModePresentation executing 时 isExecuting 且 showsCancel")
    func directModePresentation_executingState() async throws {
        let (coordinator, _) = makeCoordinator(outcomes: [
            .success(displayName: "Codex", promptBehavior: .waitForDisconnect)
        ])
        let agent = AgentInfo(type: .codex, path: "/usr/bin/codex", version: nil)
        await coordinator.connect(agent: agent, cwd: "/tmp/work")

        coordinator.sendPrompt("hello")
        await Task.yield()

        let presentation = DirectModePresentationState.build(from: coordinator.state)

        #expect(presentation.isExecuting)
        #expect(presentation.statusBar.status == .executing)
        #expect(presentation.inputBar.showsCancel == true)
        #expect(presentation.inputBar.isEnabled == false)

        coordinator.cancelPrompt()
    }

    @Test("directModePresentation failed 时为 active 且 status 为 failed")
    func directModePresentation_failedState() async throws {
        let (coordinator, _) = makeCoordinator(outcomes: [
            .failure(message: "boom")
        ])
        let agent = AgentInfo(type: .codex, path: "/usr/bin/codex", version: nil)
        await coordinator.connect(agent: agent, cwd: "/tmp/work")

        let presentation = DirectModePresentationState.build(from: coordinator.state)

        #expect(presentation.modeState == .active)
        #expect(presentation.statusBar.status == .failed)
    }

    // MARK: - 事件消费测试（直接调用 handleDirectSessionEvent）

    @Test("handleDirectSessionEvent messageReady 追加消息")
    func handleEvent_messageReadyAppendsToMessages() async throws {
        let store = try ChatViewModelTestSupport.makeInMemoryStore()
        let server = TestFixtures.makeServer()
        let vm = ChatViewModelTestSupport.makeViewModel(server: server, store: store)

        let initialCount = vm.messages.count
        let userMsg = Message(role: .user, content: "hello", source: .directAgent(agentName: "Codex"))
        await vm.handleDirectSessionEvent(.messageReady(userMsg))

        #expect(vm.messages.count == initialCount + 1)
        #expect(vm.messages.last?.content == "hello")
        #expect(vm.messages.last?.role == .user)
    }

    @Test("handleDirectSessionEvent lifecycleChanged executing 更新 isAgentExecuting 和 isStreaming")
    func handleEvent_lifecycleExecutingUpdatesFlags() async throws {
        let store = try ChatViewModelTestSupport.makeInMemoryStore()
        let server = TestFixtures.makeServer()
        let vm = ChatViewModelTestSupport.makeViewModel(server: server, store: store)

        await vm.handleDirectSessionEvent(.lifecycleChanged(.executing))

        #expect(vm.isAgentExecuting)
        #expect(vm.isStreaming)

        await vm.handleDirectSessionEvent(.lifecycleChanged(.connected))

        #expect(!vm.isAgentExecuting)
        #expect(!vm.isStreaming)
    }

    @Test("handleDirectSessionEvent lifecycleChanged executing 为直连模式插入 loading 占位")
    func handleEvent_lifecycleExecutingAppendsLoadingPlaceholder() async throws {
        let store = try ChatViewModelTestSupport.makeInMemoryStore()
        let server = TestFixtures.makeServer()
        let vm = ChatViewModelTestSupport.makeViewModel(server: server, store: store)

        await vm.handleDirectSessionEvent(.lifecycleChanged(.executing))

        #expect(vm.messages.contains { $0.role == .assistant && $0.isLoading })
    }

    @Test("handleDirectSessionEvent assistant messageReady 会移除 loading 占位")
    func handleEvent_assistantMessageReadyRemovesLoadingPlaceholder() async throws {
        let store = try ChatViewModelTestSupport.makeInMemoryStore()
        let server = TestFixtures.makeServer()
        let vm = ChatViewModelTestSupport.makeViewModel(server: server, store: store)

        vm.messages.append(Message(role: .assistant, content: "", isLoading: true, source: .directAgent(agentName: "Kimi Code CLI")))

        let assistantMsg = Message(role: .assistant, content: "hello", source: .directAgent(agentName: "Kimi Code CLI"))
        await vm.handleDirectSessionEvent(.messageReady(assistantMsg))

        #expect(vm.messages.filter { $0.isLoading }.isEmpty)
        #expect(vm.messages.last?.content == "hello")
    }

    @Test("handleDirectSessionEvent lifecycleChanged idle 清除 processing 和 agentStreamEvents")
    func handleEvent_lifecycleIdleClearsState() async throws {
        let store = try ChatViewModelTestSupport.makeInMemoryStore()
        let server = TestFixtures.makeServer()
        let vm = ChatViewModelTestSupport.makeViewModel(server: server, store: store)

        vm.isProcessing = true
        vm.agentStreamEvents = [.text("delta")]

        await vm.handleDirectSessionEvent(.lifecycleChanged(.idle))

        #expect(!vm.isProcessing)
        #expect(vm.agentStreamEvents.isEmpty)
        #expect(!vm.isAgentExecuting)
        #expect(!vm.isStreaming)
    }

    @Test("handleDirectSessionEvent error 追加系统消息")
    func handleEvent_errorAppendsSystemMessage() async throws {
        let store = try ChatViewModelTestSupport.makeInMemoryStore()
        let server = TestFixtures.makeServer()
        let vm = ChatViewModelTestSupport.makeViewModel(server: server, store: store)

        await vm.handleDirectSessionEvent(.error("connection refused"))

        let errorMessages = vm.messages.filter { $0.systemMessageType == .error }
        #expect(!errorMessages.isEmpty)
        #expect(errorMessages.first?.content.contains("connection refused") == true)
    }

    @Test("handleDirectSessionEvent streamUpdate 追加到 agentStreamEvents")
    func handleEvent_streamUpdateAppendsEvents() async throws {
        let store = try ChatViewModelTestSupport.makeInMemoryStore()
        let server = TestFixtures.makeServer()
        let vm = ChatViewModelTestSupport.makeViewModel(server: server, store: store)

        let initialTrigger = vm.streamingScrollTrigger
        await vm.handleDirectSessionEvent(.streamUpdate(.text("hello")))
        try await waitUntil(timeout: .milliseconds(500)) {
            vm.streamingScrollTrigger > initialTrigger
        }

        #expect(vm.agentStreamEvents.count == 1)
        #expect(vm.streamingScrollTrigger > initialTrigger)
    }

    @Test("handleDirectSessionEvent contextSummaryReady 追加 aiContext 消息")
    func handleEvent_contextSummaryAppendsAIContext() async throws {
        let store = try ChatViewModelTestSupport.makeInMemoryStore()
        let server = TestFixtures.makeServer()
        let vm = ChatViewModelTestSupport.makeViewModel(server: server, store: store)

        await vm.handleDirectSessionEvent(.contextSummaryReady("[Context] Direct session summary"))

        let aiContextMessages = vm.messages.filter { $0.systemMessageType == .aiContext }
        #expect(!aiContextMessages.isEmpty)
        #expect(aiContextMessages.last?.content == "[Context] Direct session summary")
    }

    @Test("permissionRequested 事件设置 directPermissionRequest 状态")
    func handlePermissionRequestedEvent() async throws {
        let store = try ChatViewModelTestSupport.makeInMemoryStore()
        let vm = ChatViewModelTestSupport.makeViewModel(
            server: TestFixtures.makeServer(), store: store)

        let request = ACPPermissionRequest(
            description: "Run npm install", tool: "execute", options: [])
        await vm.handleDirectSessionEvent(.permissionRequested(request))

        #expect(vm.directPermissionRequest?.description == "Run npm install")
    }

    @Test("lifecycle idle 时清空 directPermissionRequest")
    func lifecycleIdleClearsDirectPermissionRequest() async throws {
        let store = try ChatViewModelTestSupport.makeInMemoryStore()
        let vm = ChatViewModelTestSupport.makeViewModel(
            server: TestFixtures.makeServer(), store: store)

        let request = ACPPermissionRequest(
            description: "Pending edit", tool: "edit", options: [])
        await vm.handleDirectSessionEvent(.permissionRequested(request))
        #expect(vm.directPermissionRequest != nil)

        await vm.handleDirectSessionEvent(.lifecycleChanged(.idle))
        #expect(vm.directPermissionRequest == nil)
    }

    // MARK: - 辅助

    private func makeCoordinator(
        outcomes: [SessionFactoryOutcome],
        probes: SessionProbePool = SessionProbePool()
    ) -> (DirectSessionCoordinator, SessionProbePool) {
        let pool = probes
        let factory: DirectSessionCoordinator.SessionFactory = makeCoordinatorSessionFactory(outcomes, probes: pool)
        let coordinator = DirectSessionCoordinator(sessionFactory: factory)
        return (coordinator, pool)
    }

    private func waitUntil(timeout: Duration, condition: @MainActor @escaping () -> Bool) async throws {
        let start = ContinuousClock.now
        while !condition() {
            if ContinuousClock.now - start > timeout {
                Issue.record("Condition did not become true before timeout")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
