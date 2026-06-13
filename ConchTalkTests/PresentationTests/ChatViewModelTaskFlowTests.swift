/// 文件说明：ChatViewModelTaskFlowTests，覆盖发送与停止生成的基本状态流。
import Testing
@testable import ConchTalk
import Foundation
@preconcurrency import ACPModel

@Suite("ChatViewModel Task Flow")
@MainActor
struct ChatViewModelTaskFlowTests {
    /// 测试用超时错误。
    private struct WaitTimeoutError: Error {}

    /// 轮询等待条件满足，超时抛错。
    private func waitUntil(
        timeoutSeconds: TimeInterval = 3.0,
        condition: @MainActor () async throws -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw WaitTimeoutError()
    }

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

    @Test("observer 收到携带 currentTaskID 的状态推送后摘除排队标记")
    func observerCallback_withCurrentTaskID_removesFromQueuedMessageIDs() async throws {
        let store = try ChatViewModelTestSupport.makeInMemoryStore()
        let server = TestFixtures.makeServer()
        try await store.saveServer(server)

        let viewModel = ChatViewModelTestSupport.makeViewModel(server: server, store: store)
        let messageID = UUID()
        viewModel.markAsQueued(messageID)
        #expect(viewModel.queuedMessageIDs.contains(messageID))

        // 注册 observer 后手动构造携带 currentTaskID 的状态推送
        viewModel.attachObserver()
        viewModel.taskCoordinator.stateStore.initState(
            for: server.id,
            state: TaskStreamingState(isStreaming: true, currentTaskID: messageID)
        )
        viewModel.taskCoordinator.stateStore.notifyObserver(for: server.id)

        #expect(viewModel.queuedMessageIDs.isEmpty)
    }

    @Test("syncAfterTaskCompletion 清除不在队列中的排队标记")
    func syncAfterTaskCompletion_purgesIDsNoLongerInQueue() async throws {
        let store = try ChatViewModelTestSupport.makeInMemoryStore()
        let server = TestFixtures.makeServer()
        try await store.saveServer(server)

        let viewModel = ChatViewModelTestSupport.makeViewModel(server: server, store: store)
        let executedID = UUID()      // 已被 dequeue 执行完毕，不在队列中
        let stillQueuedID = UUID()   // 仍真实排队
        viewModel.markAsQueued(executedID)
        viewModel.markAsQueued(stillQueuedID)
        viewModel.taskCoordinator.taskQueue.enqueue(
            QueuedTask(id: stillQueuedID, serverID: server.id, text: "still queued")
        )

        await viewModel.syncAfterTaskCompletion()

        #expect(viewModel.queuedMessageIDs == [stillQueuedID])
    }

    @Test("recallQueuedMessage 撤回排队中的消息并删除持久化记录")
    func recallQueuedMessage_removesMessageFromStore() async throws {
        let store = try ChatViewModelTestSupport.makeInMemoryStore()
        let server = TestFixtures.makeServer()
        try await store.saveServer(server)

        let viewModel = ChatViewModelTestSupport.makeViewModel(server: server, store: store)
        let mockAI = try #require(viewModel.aiService as? MockAIService)
        // 首任务用 suggest_agent_connection 挂起，让第二条消息真实停留在队列中
        mockAI.streamingResponses = [[
            .toolCall(TestFixtures.makeToolCall(
                id: "call_suggest",
                toolName: "suggest_agent_connection",
                arguments: ["agent": "opencode", "reason": "hold", "cwd": "/tmp"],
                explanation: "hold first task"
            )),
            .done,
        ]]
        viewModel.sshManager.registerClientForTesting(serverID: server.id, client: NIOSSHClient())

        // 发送第一条 → 启动并挂起在代理连接等待
        viewModel.inputText = "first"
        viewModel.sendMessage()
        // 注销 observer，避免 agentPicker 探测副作用干扰挂起窗口
        viewModel.detachObserver()
        try await waitUntil {
            viewModel.taskCoordinator.stateStore.state(for: server.id)?.pendingAgentConnection == true
        }

        // 发送第二条 → 排队
        viewModel.inputText = "second"
        viewModel.sendMessage()
        let queuedID = try #require(viewModel.queuedMessageIDs.first)
        try await waitUntil {
            viewModel.taskCoordinator.taskQueue.count(for: server.id) == 1
        }

        // 撤回第二条：队列 + UI + 持久化三处全部移除
        viewModel.recallQueuedMessage(queuedID)

        #expect(!viewModel.messages.contains(where: { $0.id == queuedID }))
        #expect(viewModel.taskCoordinator.taskQueue.isEmpty(for: server.id))
        #expect(viewModel.queuedMessageIDs.isEmpty)
        try await waitUntil {
            let stored = (try? await store.fetchMessages(forServer: server.id)) ?? []
            return !stored.contains(where: { $0.id == queuedID })
        }

        // 清理挂起的首任务
        viewModel.taskCoordinator.cancelTask(for: server.id)
        try await waitUntil(timeoutSeconds: 5) {
            !viewModel.taskCoordinator.hasActiveTask(for: server.id)
        }
    }

    @Test("recallQueuedMessage 对正在执行的任务撤回失败并保留消息")
    func recallQueuedMessage_whileExecuting_keepsMessage() async throws {
        let store = try ChatViewModelTestSupport.makeInMemoryStore()
        let server = TestFixtures.makeServer()
        try await store.saveServer(server)

        let viewModel = ChatViewModelTestSupport.makeViewModel(server: server, store: store)
        let message = TestFixtures.makeMessage(role: .user, content: "executing")
        viewModel.messages = [message]
        try await store.addMessage(message, toServer: server.id)
        viewModel.markAsQueued(message.id)

        // 构造「该消息对应任务正在执行」：注册保活任务 + currentTaskID 写入状态
        let holdTask = Task<Void, Never> { try? await Task.sleep(for: .seconds(60)) }
        viewModel.taskCoordinator.lifecycleManager.registerTaskForTesting(serverID: server.id, task: holdTask)
        viewModel.taskCoordinator.stateStore.initState(
            for: server.id,
            state: TaskStreamingState(isStreaming: true, currentTaskID: message.id)
        )

        viewModel.recallQueuedMessage(message.id)

        // 撤回失败：消息保留在 UI 与 store，仅排队标记被摘除
        #expect(viewModel.messages.contains(where: { $0.id == message.id }))
        #expect(viewModel.queuedMessageIDs.isEmpty)
        let stored = try await store.fetchMessages(forServer: server.id)
        #expect(stored.contains(where: { $0.id == message.id }))

        holdTask.cancel()
    }

    @Test("入队完成前撤回：任务绝不入队，消息从 store 删除")
    func recallQueuedMessage_beforeEnqueueCompletes_messageNeverEnqueued() async throws {
        let store = try ChatViewModelTestSupport.makeInMemoryStore()
        let server = TestFixtures.makeServer()
        try await store.saveServer(server)

        let viewModel = ChatViewModelTestSupport.makeViewModel(server: server, store: store)
        let mockAI = try #require(viewModel.aiService as? MockAIService)

        // 模拟已有活跃任务 → 消息走排队路径
        viewModel.isProcessing = true
        viewModel.inputText = "queued then recalled"
        viewModel.sendMessage()
        let queuedID = try #require(viewModel.queuedMessageIDs.first)

        // 同步立刻撤回：deferredEnqueueTask 尚未执行（当前 MainActor turn 未让出）
        viewModel.recallQueuedMessage(queuedID)

        // 等 deferredEnqueueTask 跑完，验证入队前拦截生效
        await viewModel.deferredEnqueueTask?.value
        #expect(viewModel.taskCoordinator.taskQueue.isEmpty(for: server.id))
        #expect(mockAI.callCount("sendMessageStreaming") == 0)
        #expect(!viewModel.messages.contains(where: { $0.id == queuedID }))
        try await waitUntil {
            let stored = (try? await store.fetchMessages(forServer: server.id)) ?? []
            return !stored.contains(where: { $0.id == queuedID })
        }
    }

    @Test("任务完成同步与延迟入队竞态：等待入队的消息不被兜底自愈摘除标记而丢失")
    func syncAfterTaskCompletion_duringDeferredEnqueue_messageStillGetsEnqueued() async throws {
        let store = try ChatViewModelTestSupport.makeInMemoryStore()
        let server = TestFixtures.makeServer()
        try await store.saveServer(server)

        // 长对话：350 条历史 → loadMessages 只载入 100 条，
        // ensureFullHistoryLoaded 需要 3 次分页 fetch（每次一个 store actor 往返）
        let base = Date().addingTimeInterval(-3600)
        let history = (0..<350).map { i in
            TestFixtures.makeMessage(
                role: i % 2 == 0 ? .user : .assistant,
                content: "history \(i)",
                timestamp: base.addingTimeInterval(Double(i))
            )
        }
        try await store.addMessages(history, toServer: server.id)

        let viewModel = ChatViewModelTestSupport.makeViewModel(server: server, store: store)
        let mockAI = try #require(viewModel.aiService as? MockAIService)
        mockAI.streamingResponses = [[.content("B done"), .done]]
        viewModel.sshManager.registerClientForTesting(serverID: server.id, client: NIOSSHClient())

        await viewModel.loadMessages()
        #expect(viewModel.hasOlderMessages)

        // 模拟任务 A 运行中 → 消息 B 走排队路径（标记 + 延迟入队）
        viewModel.isProcessing = true
        viewModel.inputText = "message B"
        viewModel.sendMessage()
        let queuedID = try #require(viewModel.queuedMessageIDs.first)

        // A 恰在 B 的 ensureFullHistoryLoaded 期间完成 → observer 推送触发完成同步。
        // sync 只需 1 次 fetch 即达 formIntersection；B 需 3 页 fetch 才到入队前拦截检查，
        // 因此 formIntersection 必然先执行——竞态窗口被确定性复现。
        await viewModel.syncAfterTaskCompletion()

        // 等延迟入队任务跑完：B 必须被 enqueue 并执行，而非被拦截静默丢弃
        await viewModel.deferredEnqueueTask?.value
        try await waitUntil(timeoutSeconds: 10) {
            mockAI.callCount("sendMessageStreaming") == 1
        }
        try await waitUntil(timeoutSeconds: 10) {
            !viewModel.taskCoordinator.hasActiveTask(for: server.id)
                && viewModel.taskCoordinator.taskQueue.isEmpty(for: server.id)
        }
        // B 的用户消息始终保留在 store（撤回拦截未触发、未被误删）
        try await waitUntil {
            let stored = (try? await store.fetchMessages(forServer: server.id)) ?? []
            return stored.contains(where: { $0.id == queuedID })
        }

        // B 完成后的兜底自愈：重载后消息回到列表、标记摘干净、canTriggerContextBreak 恢复
        await viewModel.syncAfterTaskCompletion()
        #expect(viewModel.messages.contains(where: { $0.id == queuedID }))
        #expect(viewModel.queuedMessageIDs.isEmpty)
        #expect(viewModel.canTriggerContextBreak)
    }

    @Test("重进页面自愈：无活动任务且队列为空时复位 stale 排队状态")
    func loadMessages_resetsStaleQueuedState_whenNoActiveTaskAndEmptyQueue() async throws {
        let store = try ChatViewModelTestSupport.makeInMemoryStore()
        let server = TestFixtures.makeServer()
        try await store.saveServer(server)

        let viewModel = ChatViewModelTestSupport.makeViewModel(server: server, store: store)
        // 构造离屏完成后的 stale 状态：任务运行中用户离开（observer 注销）→
        // 任务完成（syncAfterTaskCompletion 永不触发）→ 标记与 isProcessing 残留
        let staleID = UUID()
        viewModel.markAsQueued(staleID)
        viewModel.isProcessing = true
        #expect(!viewModel.canTriggerContextBreak)

        // 重进页面：coordinator 无该 server 活动任务且队列为空 → 自愈
        await viewModel.loadMessages()

        #expect(viewModel.isProcessing == false)
        #expect(viewModel.queuedMessageIDs.isEmpty)
        #expect(viewModel.canTriggerContextBreak)
    }

    @Test("重进页面自愈保留等待入队消息的标记")
    func loadMessages_selfHeal_preservesPendingEnqueueMarkers() async throws {
        let store = try ChatViewModelTestSupport.makeInMemoryStore()
        let server = TestFixtures.makeServer()
        try await store.saveServer(server)

        let viewModel = ChatViewModelTestSupport.makeViewModel(server: server, store: store)
        let staleID = UUID()
        let pendingID = UUID()
        viewModel.markAsQueued(staleID)
        viewModel.markAsQueued(pendingID)
        viewModel.pendingEnqueueMessageIDs.insert(pendingID)
        viewModel.isProcessing = true

        await viewModel.loadMessages()

        // stale 标记被清掉，等待入队的标记保留
        #expect(viewModel.isProcessing == false)
        #expect(viewModel.queuedMessageIDs == [pendingID])
    }

    @Test("重进页面有活动任务时以队列∪等待入队修剪标记")
    func loadMessages_withActiveTask_prunesMarkersToQueueUnionPending() async throws {
        let store = try ChatViewModelTestSupport.makeInMemoryStore()
        let server = TestFixtures.makeServer()
        try await store.saveServer(server)

        let viewModel = ChatViewModelTestSupport.makeViewModel(server: server, store: store)
        let executedID = UUID()     // 已被 dequeue 执行，标记应被摘除
        let stillQueuedID = UUID()  // 仍真实排队
        let pendingID = UUID()      // 正在等待入队
        viewModel.markAsQueued(executedID)
        viewModel.markAsQueued(stillQueuedID)
        viewModel.markAsQueued(pendingID)
        viewModel.pendingEnqueueMessageIDs.insert(pendingID)
        viewModel.taskCoordinator.taskQueue.enqueue(
            QueuedTask(id: stillQueuedID, serverID: server.id, text: "still queued")
        )
        let holdTask = Task<Void, Never> { try? await Task.sleep(for: .seconds(60)) }
        viewModel.taskCoordinator.lifecycleManager.registerTaskForTesting(serverID: server.id, task: holdTask)

        await viewModel.loadMessages()

        #expect(viewModel.isProcessing == true)
        #expect(viewModel.queuedMessageIDs == [stillQueuedID, pendingID])

        holdTask.cancel()
        viewModel.taskCoordinator.taskQueue.cancelAll(for: server.id)
    }

    @Test("排队消息执行完成后 canTriggerContextBreak 恢复")
    func canTriggerContextBreak_recoversAfterQueuedTaskExecutes() async throws {
        let store = try ChatViewModelTestSupport.makeInMemoryStore()
        let server = TestFixtures.makeServer()
        try await store.saveServer(server)

        let viewModel = ChatViewModelTestSupport.makeViewModel(server: server, store: store)
        let mockAI = try #require(viewModel.aiService as? MockAIService)
        mockAI.streamingResponses = [
            [.content("first done"), .done],
            [.content("second done"), .done],
        ]
        viewModel.sshManager.registerClientForTesting(serverID: server.id, client: NIOSSHClient())

        // 同一 MainActor turn 内连发两条：第二条必然走排队路径（isProcessing 已为 true）
        viewModel.inputText = "first"
        viewModel.sendMessage()
        viewModel.inputText = "second"
        viewModel.sendMessage()
        #expect(viewModel.queuedMessageIDs.count == 1)
        #expect(!viewModel.canTriggerContextBreak)

        // 等待两个任务全部完成、队列排空
        try await waitUntil(timeoutSeconds: 10) {
            !viewModel.taskCoordinator.hasActiveTask(for: server.id)
                && viewModel.taskCoordinator.taskQueue.isEmpty(for: server.id)
        }

        // 排队标记被清除（observer 推送摘除或完成点交集兜底）、isProcessing 复位
        try await waitUntil {
            viewModel.canTriggerContextBreak
        }
        #expect(viewModel.queuedMessageIDs.isEmpty)
    }
}
