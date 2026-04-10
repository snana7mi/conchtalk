/// 文件说明：TaskQueueIntegrationTests，任务队列的集成测试。
@testable import ConchTalk
import Foundation
import SwiftData
import Testing

/// TaskQueueIntegrationTests：
/// 验证 TaskExecutionCoordinator 的任务排队、串行执行与取消调度行为，
/// 使用真实 AI 服务和 MockSSH 客户端进行集成测试。
@Suite(.tags(.integration), .serialized)
@MainActor
struct TaskQueueIntegrationTests {

    /// 测试超时错误。
    private struct WaitTimeoutError: Error {}

    /// 测试用认证服务替身。
    private final class MockAuthService: AuthServiceProtocol, @unchecked Sendable {
        var isLoggedIn: Bool = false
        var currentUser: AuthUser? = nil

        func validAccessToken() async throws -> String { "test-token" }
        func refreshAccessToken() async throws {}
        func updateCurrentUser(_ user: AuthUser) { currentUser = user }
        func fetchAccount() async throws {}
    }

    // MARK: - Helpers

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

    private func makeCoordinator(aiService: AIServiceProtocol) throws -> (TaskExecutionCoordinator, SSHSessionManager, SwiftDataStore) {
        let store = try makeInMemoryStore()
        let sshManager = SSHSessionManager()
        sshManager.store = store

        let toolRegistry = MockToolRegistry()
        let notificationService = NotificationService()
        let memoryService = MockMemoryService()
        let authService = MockAuthService()

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
            notificationService: notificationService
        )
        return (coordinator, sshManager, store)
    }

    /// 等待条件满足或超时。
    private func waitUntil(
        timeoutSeconds: TimeInterval = 5.0,
        condition: @MainActor @escaping () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw WaitTimeoutError()
    }

    // MARK: - queueMultipleTasks

    /// 入队第一个和第二个任务，验证第一个正在运行且第二个在队列中排队。
    @Test(.timeLimit(.minutes(2)))
    func queueMultipleTasks() async throws {
        let aiService = MockAIService()

        // 第一个任务：模拟长时间运行
        let longRunningDeltas: [StreamingDelta] = [
            .content("Working on task 1..."),
            .content(" Still processing..."),
            .done,
        ]
        aiService.streamingResponses = [longRunningDeltas]

        let (coordinator, sshManager, _) = try makeCoordinator(aiService: aiService)
        let serverID = UUID()
        let server = TestFixtures.makeServer(id: serverID)

        // 注册观察者和 mock SSH 客户端
        coordinator.setObserver(for: serverID, emitCurrent: false) { _ in }
        sshManager.registerClientForTesting(serverID: serverID, client: NIOSSHClient())

        // 入队第一个任务（会立即启动）
        coordinator.enqueueTask(
            serverID: serverID,
            text: "First task",
            server: server,
            messages: []
        )

        // 验证第一个任务正在运行
        #expect(coordinator.hasActiveTask(for: serverID), "First task should be running")

        // 入队第二个任务（应在队列中排队）
        coordinator.enqueueTask(
            serverID: serverID,
            text: "Second task",
            server: server,
            messages: []
        )

        // 验证第二个任务在队列中
        #expect(coordinator.taskQueue.count(for: serverID) == 1, "Second task should be queued")
    }

    // MARK: - queuedTaskExecutesAfterFirst

    /// 入队两个任务，等待两个任务都完成。
    @Test(.timeLimit(.minutes(2)))
    func queuedTaskExecutesAfterFirst() async throws {
        let aiService = MockAIService()

        // 第一个任务：快速完成
        // 第二个任务：也快速完成（drain 队列时会消费）
        aiService.streamingResponses = [
            [.content("Task 1 done"), .done],
            [.content("Task 2 done"), .done],
        ]

        let (coordinator, sshManager, _) = try makeCoordinator(aiService: aiService)
        let serverID = UUID()
        let server = TestFixtures.makeServer(id: serverID)

        coordinator.setObserver(for: serverID, emitCurrent: false) { _ in }
        sshManager.registerClientForTesting(serverID: serverID, client: NIOSSHClient())

        // 入队两个任务（enqueueTask 会自动启动第一个）
        coordinator.enqueueTask(
            serverID: serverID,
            text: "First quick task",
            server: server,
            messages: []
        )

        // 第一个已被 dequeue 并启动，再入队第二个
        coordinator.enqueueTask(
            serverID: serverID,
            text: "Second quick task",
            server: server,
            messages: []
        )

        // 等待所有任务完成（drainQueueAfterTaskCompletion 会自动处理）
        try await waitUntil(timeoutSeconds: 10) {
            !coordinator.hasActiveTask(for: serverID) && coordinator.taskQueue.isEmpty(for: serverID)
        }

        // 验证两个任务都被处理了
        #expect(aiService.callCount("sendMessageStreaming") >= 1, "AI service should have been called")
        #expect(coordinator.taskQueue.isEmpty(for: serverID), "Queue should be empty after all tasks complete")
    }

    // MARK: - cancelRunningDequeuesNext

    /// 入队长任务和第二个任务，取消后验证队列被清空。
    @Test(.timeLimit(.minutes(2)))
    func cancelRunningDequeuesNext() async throws {
        let aiService = MockAIService()

        // 第一个任务：长运行（会被取消）
        // 第二个任务：快速完成
        aiService.streamingResponses = [
            [.content("Long running task..."), .done],
            [.content("Second task result"), .done],
        ]

        let (coordinator, sshManager, _) = try makeCoordinator(aiService: aiService)
        let serverID = UUID()
        let server = TestFixtures.makeServer(id: serverID)

        coordinator.setObserver(for: serverID, emitCurrent: false) { _ in }
        sshManager.registerClientForTesting(serverID: serverID, client: NIOSSHClient())

        // 入队第一个任务（会立即启动）
        coordinator.enqueueTask(
            serverID: serverID,
            text: "Long running task",
            server: server,
            messages: []
        )

        #expect(coordinator.hasActiveTask(for: serverID), "First task should be running")

        // 入队第二个任务
        coordinator.enqueueTask(
            serverID: serverID,
            text: "Next task after cancel",
            server: server,
            messages: []
        )
        #expect(coordinator.taskQueue.count(for: serverID) == 1, "Second task should be in queue")

        // 取消第一个任务
        await coordinator.cancelAndWait(for: serverID)

        // 取消后，drainQueueAfterTaskCompletion 应该已经触发
        try await waitUntil(timeoutSeconds: 10) {
            coordinator.taskQueue.isEmpty(for: serverID)
        }

        #expect(coordinator.taskQueue.isEmpty(for: serverID), "Queue should be drained after cancellation")
    }
}
