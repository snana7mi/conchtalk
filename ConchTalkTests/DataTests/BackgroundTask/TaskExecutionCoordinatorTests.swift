/// 文件说明：TaskExecutionCoordinatorTests，验证 TaskExecutionCoordinator 的排队、执行、取消与状态管理。
import Testing
@testable import ConchTalk
import Foundation
import SwiftData

@Suite("TaskExecutionCoordinator")
@MainActor
struct TaskExecutionCoordinatorTests {

    // MARK: - Test Helpers

    /// 测试用超时错误。
    private struct WaitTimeoutError: Error {}

    /// 测试用认证服务替身。
    private final class StubAuthService: AuthServiceProtocol, @unchecked Sendable {
        var isLoggedIn: Bool = false
        var currentUser: AuthUser? = nil
        func validAccessToken() async throws -> String { "test-token" }
        func refreshAccessToken() async throws {}
        func updateCurrentUser(_ user: AuthUser) { currentUser = user }
        func fetchAccount() async throws {}
    }

    /// 构建内存数据库。
    private func makeInMemoryStore() throws -> SwiftDataStore {
        let schema = Schema([
            ServerModel.self,
            MessageModel.self,
            ServerGroupModel.self,
            SSHKeyModel.self,
            MemoryModel.self,
            MemoryEntryModel.self,
            SystemProfileModel.self,
        ])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        return SwiftDataStore(modelContainer: container)
    }

    /// 构建完整的 coordinator 及辅助对象。
    private func makeCoordinator(
        aiService: MockAIService = MockAIService()
    ) throws -> (TaskExecutionCoordinator, SSHSessionManager, SwiftDataStore) {
        let store = try makeInMemoryStore()
        let sshManager = SSHSessionManager()
        sshManager.store = store

        let toolRegistry = MockToolRegistry()
        let memoryService = MockMemoryService()
        let authService = StubAuthService()
        let notificationService = NotificationService()

        let contextFactory = TaskExecutionContextFactory(
            sshManager: sshManager,
            toolRegistry: toolRegistry,
            memoryContextProvider: memoryService,
            authService: authService,
            memoryService: nil,
            store: store
        )

        let messageRepository = ChatMessageRepository(store: store)

        let coordinator = TaskExecutionCoordinator(
            taskQueue: PerServerTaskQueue(),
            stateStore: TaskStreamingStateStore(),
            lifecycleManager: TaskLifecycleManager(),
            messageRepository: messageRepository,
            contextFactory: contextFactory,
            aiService: aiService,
            keepAlive: BackgroundKeepAlive(),
            notificationService: notificationService,
            subagentRegistry: SubagentRegistry(preloaded: [])
        )

        return (coordinator, sshManager, store)
    }

    /// 轮询等待条件满足，超时抛错。
    private func waitUntil(
        timeoutSeconds: TimeInterval = 3.0,
        condition: @MainActor @escaping () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw WaitTimeoutError()
    }

    /// 构建 suggest_agent_connection 工具调用（特殊拦截，不需要工具注册表）。
    private func makeSuggestAgentToolCall() -> ToolCall {
        let args: [String: Any] = [
            "agent": "opencode",
            "reason": "Need coding agent",
            "cwd": "/tmp",
        ]
        let json = try! JSONSerialization.data(withJSONObject: args)
        return ToolCall(
            id: "call_suggest_agent",
            toolName: "suggest_agent_connection",
            argumentsJSON: json,
            explanation: "Suggest connecting coding agent"
        )
    }

    // MARK: - Enqueue Tests

    @Test("enqueue 在服务器空闲时立即启动任务")
    func enqueue_startsTaskImmediatelyWhenServerIsIdle() async throws {
        let aiService = MockAIService()
        // AI 直接返回文本回复
        aiService.streamingResponses = [[
            .content("Hello from AI"),
            .done,
        ]]

        let (coordinator, sshManager, store) = try makeCoordinator(aiService: aiService)
        let server = TestFixtures.makeServer(id: UUID())

        // 注册 SSH 客户端
        sshManager.registerClientForTesting(serverID: server.id, client: NIOSSHClient())

        // 注册 observer
        coordinator.setObserver(for: server.id, emitCurrent: false) { _ in }

        // 入队
        coordinator.enqueueTask(
            serverID: server.id,
            text: "say hello",
            server: server,
            messages: []
        )

        // 应立即有活跃任务
        #expect(coordinator.hasActiveTask(for: server.id))

        // 等待任务完成
        try await waitUntil {
            !coordinator.hasActiveTask(for: server.id)
        }

        // 验证 AI 被调用
        #expect(aiService.didCall("sendMessageStreaming"))

        // 验证消息被持久化
        let messages = try await store.fetchMessages(forServer: server.id)
        #expect(!messages.isEmpty)
    }

    @Test("enqueue 保持不同服务器的任务隔离")
    func enqueue_keepsTasksIsolatedPerServer() async throws {
        let aiService = MockAIService()
        // 两次调用各返回一条文本
        aiService.streamingResponses = [
            [.content("Reply A"), .done],
            [.content("Reply B"), .done],
        ]

        let (coordinator, sshManager, _) = try makeCoordinator(aiService: aiService)
        let serverA = TestFixtures.makeServer(id: UUID(), name: "Server A")
        let serverB = TestFixtures.makeServer(id: UUID(), name: "Server B")

        sshManager.registerClientForTesting(serverID: serverA.id, client: NIOSSHClient())
        sshManager.registerClientForTesting(serverID: serverB.id, client: NIOSSHClient())

        coordinator.setObserver(for: serverA.id, emitCurrent: false) { _ in }
        coordinator.setObserver(for: serverB.id, emitCurrent: false) { _ in }

        // 同时入队两个服务器的任务
        coordinator.enqueueTask(serverID: serverA.id, text: "task A", server: serverA, messages: [])
        coordinator.enqueueTask(serverID: serverB.id, text: "task B", server: serverB, messages: [])

        // 两个服务器都应有活跃任务
        #expect(coordinator.hasActiveTask(for: serverA.id))
        #expect(coordinator.hasActiveTask(for: serverB.id))

        // 等待两个都完成
        try await waitUntil(timeoutSeconds: 5) {
            !coordinator.hasActiveTask(for: serverA.id) && !coordinator.hasActiveTask(for: serverB.id)
        }
    }

    @Test("执行过程中发出中间消息并最终完成")
    func executionPublishesIntermediateMessagesAndFinalCompletion() async throws {
        let aiService = MockAIService()
        // AI 先调用工具，再回复文本
        let toolCall = TestFixtures.makeToolCall(
            id: "call_1",
            toolName: "execute_ssh_command",
            arguments: ["command": "echo hi"],
            explanation: "Echo hi"
        )
        aiService.streamingResponses = [
            [.toolCall(toolCall), .done],
            [.content("Done, output was: hi"), .done],
        ]

        let (coordinator, sshManager, store) = try makeCoordinator(aiService: aiService)
        let server = TestFixtures.makeServer(id: UUID())

        sshManager.registerClientForTesting(serverID: server.id, client: NIOSSHClient())

        // 收集 observer 推送
        var receivedStates: [TaskStreamingState] = []
        coordinator.setObserver(for: server.id, emitCurrent: false) { state in
            receivedStates.append(state)
        }

        coordinator.enqueueTask(
            serverID: server.id,
            text: "echo hi",
            server: server,
            messages: []
        )

        // 等待任务完成
        try await waitUntil(timeoutSeconds: 5) {
            !coordinator.hasActiveTask(for: server.id)
        }

        // 至少收到过一次 observer 推送
        #expect(!receivedStates.isEmpty)

        // 验证消息被持久化（工具调用消息 + 最终助手消息）
        let messages = try await store.fetchMessages(forServer: server.id)
        #expect(messages.count >= 1)
    }

    @Test("取消任务时持久化部分助手消息")
    func cancellation_persistsPartialAssistantMessageWhenAvailable() async throws {
        let aiService = MockAIService()
        // AI 流式输出内容后抛出 CancellationError，模拟流式传输中途被取消的场景。
        // 取消处理逻辑应将已流式输出的部分内容持久化为助手消息。
        aiService.streamingResponses = [
            [.content("Partial streaming content from AI")],
        ]
        aiService.throwCancellationAfterYielding = true

        let (coordinator, sshManager, store) = try makeCoordinator(aiService: aiService)
        let server = TestFixtures.makeServer(id: UUID())

        sshManager.registerClientForTesting(serverID: server.id, client: NIOSSHClient())
        coordinator.setObserver(for: server.id, emitCurrent: false) { _ in }

        coordinator.enqueueTask(
            serverID: server.id,
            text: "say something",
            server: server,
            messages: []
        )

        // 等待任务完成（CancellationError 触发后任务结束）
        try await waitUntil(timeoutSeconds: 5) {
            !coordinator.hasActiveTask(for: server.id)
        }

        // 验证任务已清理
        #expect(coordinator.stateStore.state(for: server.id) == nil)

        // 验证部分助手消息被持久化到 store
        let messages = try await store.fetchMessages(forServer: server.id)
        let assistantMessages = messages.filter { $0.role == .assistant }
        #expect(!assistantMessages.isEmpty, "部分助手消息应被持久化")
        #expect(assistantMessages.first?.content.contains("Partial streaming content") == true)
    }

    // MARK: - Queue Drain Tests

    @Test("enqueue 多条任务按 FIFO 顺序执行")
    func enqueue_multipleTasksDrainInFIFOOrder() async throws {
        let aiService = MockAIService()
        aiService.streamingResponses = [
            [.content("Reply 1"), .done],
            [.content("Reply 2"), .done],
        ]

        let (coordinator, sshManager, _) = try makeCoordinator(aiService: aiService)
        let server = TestFixtures.makeServer(id: UUID())

        sshManager.registerClientForTesting(serverID: server.id, client: NIOSSHClient())
        coordinator.setObserver(for: server.id, emitCurrent: false) { _ in }

        // 入队两条任务
        coordinator.enqueueTask(serverID: server.id, text: "first", server: server, messages: [])
        coordinator.enqueueTask(serverID: server.id, text: "second", server: server, messages: [])

        // 队列应有 1 条待执行（第一条已启动）
        #expect(coordinator.taskQueue.count(for: server.id) == 1)

        // 等待全部完成
        try await waitUntil(timeoutSeconds: 5) {
            !coordinator.hasActiveTask(for: server.id) && coordinator.taskQueue.isEmpty(for: server.id)
        }

        // 两次都应该调用了 AI
        #expect(aiService.callCount("sendMessageStreaming") == 2)
    }

    // MARK: - Observer Tests

    @Test("setObserver 注册后立即推送当前状态")
    func setObserver_emitsCurrentStateOnRegistration() async throws {
        let (coordinator, _, _) = try makeCoordinator()
        let serverID = UUID()

        // 手动初始化一个状态
        coordinator.stateStore.initState(for: serverID, state: TaskStreamingState(isStreaming: true))

        var receivedState: TaskStreamingState?
        coordinator.setObserver(for: serverID, emitCurrent: true) { state in
            receivedState = state
        }

        #expect(receivedState != nil)
        #expect(receivedState?.isStreaming == true)
    }

    // MARK: - TaskID 贯通 Tests（撤回排队消息修复）

    @Test("enqueueTask 显式 taskID 贯通到 QueuedTask.id")
    func enqueueTask_withExplicitTaskID_queuedTaskUsesIt() async throws {
        let aiService = MockAIService()
        // 首任务用 suggest_agent_connection 挂起等待用户选择，保证第二条停留在队列中
        aiService.streamingResponses = [[
            .toolCall(makeSuggestAgentToolCall()),
            .done,
        ]]

        let (coordinator, sshManager, _) = try makeCoordinator(aiService: aiService)
        let server = TestFixtures.makeServer(id: UUID())
        sshManager.registerClientForTesting(serverID: server.id, client: NIOSSHClient())
        coordinator.setObserver(for: server.id, emitCurrent: false) { _ in }

        // 首任务启动并挂起在代理连接等待
        coordinator.enqueueTask(serverID: server.id, text: "first", server: server, messages: [])
        try await waitUntil {
            coordinator.stateStore.state(for: server.id)?.pendingAgentConnection == true
        }

        // 第二条显式传 taskID（模拟用户消息 ID）
        let messageID = UUID()
        coordinator.enqueueTask(taskID: messageID, serverID: server.id, text: "second", server: server, messages: [])

        let queuedTasks = coordinator.taskQueue.tasks(for: server.id)
        #expect(queuedTasks.count == 1)
        #expect(queuedTasks.first?.id == messageID)

        // 清理：取消首任务，等待队列排空（drain 会启动第二条并以默认 .done 快速结束）
        coordinator.cancelTask(for: server.id)
        try await waitUntil(timeoutSeconds: 5) {
            !coordinator.hasActiveTask(for: server.id) && coordinator.taskQueue.isEmpty(for: server.id)
        }
    }

    @Test("cancelQueuedTask 按消息 ID 移除排队任务且该任务不再执行")
    func cancelQueuedTask_withMessageID_removesQueuedTask_taskNeverExecutes() async throws {
        let aiService = MockAIService()
        aiService.streamingResponses = [[
            .toolCall(makeSuggestAgentToolCall()),
            .done,
        ]]

        let (coordinator, sshManager, _) = try makeCoordinator(aiService: aiService)
        let server = TestFixtures.makeServer(id: UUID())
        sshManager.registerClientForTesting(serverID: server.id, client: NIOSSHClient())
        coordinator.setObserver(for: server.id, emitCurrent: false) { _ in }

        coordinator.enqueueTask(serverID: server.id, text: "first", server: server, messages: [])
        try await waitUntil {
            coordinator.stateStore.state(for: server.id)?.pendingAgentConnection == true
        }

        let messageID = UUID()
        coordinator.enqueueTask(taskID: messageID, serverID: server.id, text: "second", server: server, messages: [])
        #expect(coordinator.taskQueue.count(for: server.id) == 1)

        // 用消息 ID 撤回排队任务（修复前 QueuedTask.id 是内部新 UUID，永不匹配）
        let removed = coordinator.cancelQueuedTask(serverID: server.id, taskID: messageID)
        #expect(removed == true)
        #expect(coordinator.taskQueue.isEmpty(for: server.id))

        // 释放首任务
        coordinator.cancelTask(for: server.id)
        try await waitUntil(timeoutSeconds: 5) {
            !coordinator.hasActiveTask(for: server.id)
        }

        // 被撤回的任务从未触发新的 AI 首轮调用（只有首任务一次）
        #expect(aiService.callCount("sendMessageStreaming") == 1)
    }

    @Test("startTask 将 currentTaskID 写入流式状态")
    func startTask_publishesCurrentTaskID_inStreamingState() async throws {
        let aiService = MockAIService()
        aiService.streamingResponses = [[
            .toolCall(makeSuggestAgentToolCall()),
            .done,
        ]]

        let (coordinator, sshManager, _) = try makeCoordinator(aiService: aiService)
        let server = TestFixtures.makeServer(id: UUID())
        sshManager.registerClientForTesting(serverID: server.id, client: NIOSSHClient())
        coordinator.setObserver(for: server.id, emitCurrent: false) { _ in }

        let messageID = UUID()
        coordinator.enqueueTask(taskID: messageID, serverID: server.id, text: "task", server: server, messages: [])

        // 任务启动并挂起在代理连接等待，此时状态仍在 stateStore 中可查
        try await waitUntil {
            coordinator.stateStore.state(for: server.id)?.pendingAgentConnection == true
        }
        #expect(coordinator.stateStore.state(for: server.id)?.currentTaskID == messageID)

        coordinator.cancelTask(for: server.id)
        try await waitUntil(timeoutSeconds: 5) {
            !coordinator.hasActiveTask(for: server.id)
        }
    }

    @Test("isExecutingTask 仅在该任务正在执行时为 true")
    func isExecutingTask_matchesOnlyActiveCurrentTask() async throws {
        let (coordinator, _, _) = try makeCoordinator()
        let serverID = UUID()
        let taskID = UUID()

        // 无活跃任务 → false
        #expect(!coordinator.isExecutingTask(taskID: taskID, serverID: serverID))

        // 构造执行态：注册保活任务 + 写入 currentTaskID
        let holdTask = Task<Void, Never> { try? await Task.sleep(for: .seconds(60)) }
        coordinator.lifecycleManager.registerTaskForTesting(serverID: serverID, task: holdTask)
        coordinator.stateStore.initState(
            for: serverID,
            state: TaskStreamingState(isStreaming: true, currentTaskID: taskID)
        )

        #expect(coordinator.isExecutingTask(taskID: taskID, serverID: serverID))
        // 其他 taskID → false
        #expect(!coordinator.isExecutingTask(taskID: UUID(), serverID: serverID))

        holdTask.cancel()
    }

    // MARK: - Cancel Tests

    @Test("cancelTask 取消后 hasActiveTask 变为 false")
    func cancelTask_clearsActiveState() async throws {
        let aiService = MockAIService()
        // suggest_agent_connection 会挂起等待用户选择，方便测试取消
        let agentToolCall = makeSuggestAgentToolCall()
        aiService.streamingResponses = [[
            .toolCall(agentToolCall),
            .done,
        ]]

        let (coordinator, sshManager, _) = try makeCoordinator(aiService: aiService)
        let server = TestFixtures.makeServer(id: UUID())

        sshManager.registerClientForTesting(serverID: server.id, client: NIOSSHClient())
        coordinator.setObserver(for: server.id, emitCurrent: false) { _ in }

        coordinator.enqueueTask(serverID: server.id, text: "connect agent", server: server, messages: [])

        // 等待进入代理连接等待
        try await waitUntil {
            coordinator.stateStore.state(for: server.id)?.pendingAgentConnection == true
        }

        // 取消
        coordinator.cancelTask(for: server.id)

        // 等待清理完成
        try await waitUntil {
            !coordinator.hasActiveTask(for: server.id)
        }

        #expect(!coordinator.hasActiveTask(for: server.id))
    }
}
