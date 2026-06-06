/// 文件说明：TaskExecutionCoordinatorCancelTests，覆盖任务取消路径的关键回归场景。
import Testing
@testable import ConchTalk
import Foundation
import SwiftData

@Suite("TaskExecutionCoordinator Cancel")
@MainActor
struct TaskExecutionCoordinatorCancelTests {
    /// 测试用超时错误。
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

    private func makeCoordinator(aiService: MockAIService) throws -> (TaskExecutionCoordinator, SSHSessionManager) {
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
            notificationService: notificationService,
            subagentRegistry: SubagentRegistry(preloaded: [])
        )
        return (coordinator, sshManager)
    }

    private func makeSuggestAgentToolCall() throws -> ToolCall {
        let args: [String: Any] = [
            "agent": "opencode",
            "reason": "Need coding agent",
            "cwd": "/tmp",
        ]
        let json = try JSONSerialization.data(withJSONObject: args)
        return ToolCall(
            id: "call_suggest_agent",
            toolName: "suggest_agent_connection",
            argumentsJSON: json,
            explanation: "Suggest connecting coding agent"
        )
    }

    private func waitUntil(
        timeoutSeconds: TimeInterval = 2.0,
        condition: @MainActor @escaping () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw WaitTimeoutError()
    }

    @Test("cancelAndWait 在等待代理连接时可完成清理")
    func cancelAndWaitResolvesPendingAgentConnection() async throws {
        let aiService = MockAIService()
        aiService.streamingResponses = [[
            .toolCall(try makeSuggestAgentToolCall()),
            .done,
        ]]

        let (coordinator, sshManager) = try makeCoordinator(aiService: aiService)
        let server = TestFixtures.makeServer(id: UUID())

        coordinator.setObserver(for: server.id, emitCurrent: false) { _ in }
        sshManager.registerClientForTesting(serverID: server.id, client: NIOSSHClient())

        coordinator.enqueueTask(
            serverID: server.id,
            text: "connect coding agent",
            server: server,
            messages: []
        )

        try await waitUntil {
            coordinator.stateStore.state(for: server.id)?.pendingAgentConnection == true
        }

        await coordinator.cancelAndWait(for: server.id)

        #expect(coordinator.hasActiveTask(for: server.id) == false)
        #expect(coordinator.stateStore.state(for: server.id) == nil)
    }

    @Test("cancelTask 在等待代理连接时不会挂起任务")
    func cancelTaskResolvesPendingAgentConnection() async throws {
        let aiService = MockAIService()
        aiService.streamingResponses = [[
            .toolCall(try makeSuggestAgentToolCall()),
            .done,
        ]]

        let (coordinator, sshManager) = try makeCoordinator(aiService: aiService)
        let server = TestFixtures.makeServer(id: UUID())

        coordinator.setObserver(for: server.id, emitCurrent: false) { _ in }
        sshManager.registerClientForTesting(serverID: server.id, client: NIOSSHClient())

        coordinator.enqueueTask(
            serverID: server.id,
            text: "connect coding agent",
            server: server,
            messages: []
        )

        try await waitUntil {
            coordinator.stateStore.state(for: server.id)?.pendingAgentConnection == true
        }

        coordinator.cancelTask(for: server.id)

        try await waitUntil {
            coordinator.hasActiveTask(for: server.id) == false
        }
        #expect(coordinator.stateStore.state(for: server.id) == nil)
    }
}
