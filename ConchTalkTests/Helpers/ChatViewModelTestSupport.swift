/// 文件说明：ChatViewModelTestSupport，集中提供 ChatViewModel 测试所需的 in-memory store 与依赖构造。
import Testing
@testable import ConchTalk
import Foundation
import SwiftData

@MainActor
enum ChatViewModelTestSupport {
    /// 测试用认证服务替身。
    final class MockAuthService: AuthServiceProtocol, @unchecked Sendable {
        var isLoggedIn: Bool = false
        var currentUser: AuthUser? = nil

        func validAccessToken() async throws -> String { "test-token" }
        func refreshAccessToken() async throws {}
        func updateCurrentUser(_ user: AuthUser) { currentUser = user }
        func fetchAccount() async throws {}
    }

    static func makeInMemoryStore() throws -> SwiftDataStore {
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

    static func makeViewModel(
        server: Server,
        store: SwiftDataStore,
        speechCoordinator: SpeechInputCoordinator? = nil
    ) -> ChatViewModel {
        let sshManager = SSHSessionManager()
        sshManager.store = store

        let aiService = MockAIService()
        let toolRegistry = MockToolRegistry()
        let keychainService = MockKeychainService()
        let memoryService = MockMemoryService()
        let authService = MockAuthService()

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
        let entryStore = MockMemoryEntryStore()
        let retainService = RetainService(
            aiService: aiService,
            memoryWriter: memoryService,
            entryStore: entryStore
        )

        let resolvedSpeechCoordinator = speechCoordinator ?? SpeechInputCoordinator(speechRecognitionService: SpeechRecognitionService(permissionManager: AudioPermissionManager()))

        return ChatViewModel(
            server: server,
            store: store,
            sshManager: sshManager,
            aiService: aiService,
            toolRegistry: toolRegistry,
            keychainService: keychainService,
            taskCoordinator: coordinator,
            memoryReader: memoryService,
            retainService: retainService,
            speechCoordinator: resolvedSpeechCoordinator,
            authService: MockAuthService()
        )
    }
}
