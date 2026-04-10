/// 文件说明：DependencyContainer，负责应用级依赖装配与对象创建。
import Foundation
import SwiftData

/// DependencyContainer：集中装配应用运行所需依赖并提供工厂方法。
@MainActor
@Observable
final class DependencyContainer {
    let modelContainer: ModelContainer
    let store: SwiftDataStore
    let sshManager: SSHSessionManager
    let keychainService: KeychainService
    let authService: AuthService
    let aiService: AIProxyService
    let toolRegistry: ToolRegistry
    let skillRegistry: SkillRegistry
    let notificationService: NotificationService
    let memoryService: MemoryService
    // MARK: - 新架构组件（Context + Memory 服务链）

    let tokenEstimator: TokenEstimator
    let recallService: RecallService
    let retainService: RetainService
    let reflectService: ReflectService
    let contextBuilder: ContextBuilder
    let contextCompactor: ContextCompactor
    let audioPermissionManager: AudioPermissionManager
    let speechRecognitionService: SpeechRecognitionService
    let metricsPoller: ServerMetricsPoller
    let relayActivityTracker: RelayActivityTracker
    let syncService: SyncService
    let subscriptionService: SubscriptionService
    let relayTokenService: RelayTokenService
    let dlcInstaller: DLCInstaller

    // MARK: - 新架构协调器

    /// 任务执行协调器（编排 AI 任务的排队、执行、审批、生命周期）。
    let taskExecutionCoordinator: TaskExecutionCoordinator

    /// 异步工厂方法：将重量级 I/O（ModelContainer、Skill 文件加载）移到后台线程，
    /// 避免阻塞主线程导致首帧卡顿。
    static func create() async -> DependencyContainer {
        // 提前创建 Application Support 目录，避免 CoreData 首次启动时的冗余错误日志
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)

        // ModelContainer 创建是主要瓶颈（SQLite 打开 + schema 迁移），移到后台线程
        let modelContainer = await Task.detached(priority: .userInitiated) {
            let schema = Schema([
                ServerModel.self,
                MessageModel.self,
                ServerGroupModel.self,
                SSHKeyModel.self,
                MemoryModel.self,
                MemoryEntryModel.self,
                SystemProfileModel.self,
            ])
            let modelConfiguration = ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: false
            )
            do {
                return try ModelContainer(for: schema, configurations: [modelConfiguration])
            } catch {
                // Schema 变更后旧数据库无法迁移，销毁重建
                let storeURL = modelConfiguration.url
                try? FileManager.default.removeItem(at: storeURL)
                // 同时删除 WAL 和 SHM 文件
                let walURL = storeURL.appendingPathExtension("wal")   // 实际路径是 .store-wal
                let shmURL = storeURL.appendingPathExtension("shm")
                try? FileManager.default.removeItem(at: walURL)
                try? FileManager.default.removeItem(at: shmURL)
                // 尝试用 -wal / -shm 后缀
                let dashWal = URL(fileURLWithPath: storeURL.path + "-wal")
                let dashShm = URL(fileURLWithPath: storeURL.path + "-shm")
                try? FileManager.default.removeItem(at: dashWal)
                try? FileManager.default.removeItem(at: dashShm)
                do {
                    return try ModelContainer(for: schema, configurations: [modelConfiguration])
                } catch {
                    fatalError("Could not create ModelContainer after reset: \(error)")
                }
            }
        }.value

        // Skill 加载留在主线程（6 个 .md 文件，开销很小，避免跨 actor 传递问题）
        let skills = SkillRegistry.loadSkillsFromBundle()

        return DependencyContainer(modelContainer: modelContainer, preloadedSkills: skills)
    }

    /// 使用预加载的组件初始化（由 create() 调用，主线程上只做轻量 wiring）。
    private init(modelContainer: ModelContainer, preloadedSkills: [Skill]) {
        self.modelContainer = modelContainer
        self.store = SwiftDataStore(modelContainer: modelContainer)

        // Services（纯内存构造，无 I/O）
        let sshMgr = SSHSessionManager()
        self.sshManager = sshMgr

        // Skill Registry（使用预加载数据，不再读磁盘）
        self.skillRegistry = SkillRegistry(preloaded: preloadedSkills)

        // Auth 服务需要在 Tool Registry 之前创建，以决定是否注入 WebSearchTool
        let keychainSvc = KeychainService()
        self.keychainService = keychainSvc
        let authSvc = AuthService(keychainService: keychainSvc)
        self.authService = authSvc

        // Tool Registry（需要 authService 决定是否注入 WebSearchTool）
        self.toolRegistry = ToolRegistryFactory.makeBaseRegistry(
            skillRegistry: skillRegistry,
            authService: authSvc
        )
        sshMgr.store = store
        self.aiService = AIProxyService(keychainService: keychainService, toolRegistry: toolRegistry, skillRegistry: skillRegistry, authService: authService)
        self.notificationService = NotificationService()

        // 2-phase init：先创建 MemoryService，再注入 RecallService 解决循环依赖
        let tokenEst = TokenEstimator()
        self.tokenEstimator = tokenEst
        let memorySvc = MemoryService(store: store)
        self.memoryService = memorySvc
        let recallSvc = RecallService(entryStore: memorySvc, tokenEstimator: tokenEst)
        self.recallService = recallSvc
        // Task 在 init 里无法 async，通过 Task.detached 完成 2-phase 注入
        Task { await memorySvc.setRecallService(recallSvc) }
        let aiSvc = aiService
        let retainSvc = RetainService(aiService: aiSvc, memoryWriter: memorySvc, entryStore: memorySvc)
        self.retainService = retainSvc
        let reflectSvc = ReflectService(aiService: aiSvc, entryStore: memorySvc, memoryWriter: memorySvc, memoryReader: memorySvc)
        self.reflectService = reflectSvc
        let ctxBuilder = ContextBuilder(memoryContextProvider: memorySvc, tokenEstimator: tokenEst)
        let ctxCompactor = ContextCompactor(aiService: aiSvc, retainService: retainSvc, reflectService: reflectSvc, tokenEstimator: tokenEst)
        self.contextBuilder = ctxBuilder
        self.contextCompactor = ctxCompactor

        let audioPermMgr = AudioPermissionManager()
        self.audioPermissionManager = audioPermMgr
        self.speechRecognitionService = SpeechRecognitionService(permissionManager: audioPermMgr)

        self.metricsPoller = ServerMetricsPoller(sshManager: sshMgr)
        self.relayActivityTracker = RelayActivityTracker()

        // Cloud Sync
        let syncCrypto = SyncCryptoService(keychainService: keychainSvc)
        let syncAPIClient = SyncAPIClient(authService: authSvc)
        let syncCollector = SyncChangeCollector(store: store, keychainService: keychainSvc)
        let syncMerge = SyncMergeEngine(store: store, keychainService: keychainSvc)
        self.syncService = SyncService(crypto: syncCrypto, apiClient: syncAPIClient,
                                       collector: syncCollector, mergeEngine: syncMerge,
                                       store: store, authService: authSvc)

        // Subscription（RevenueCat 管理购买，webhook 更新 tier）
        self.subscriptionService = SubscriptionService(authService: authSvc)

        // Relay（中转模式 token 管理）
        self.relayTokenService = RelayTokenService(authService: authSvc)
        self.dlcInstaller = DLCInstaller(relayTokenService: relayTokenService, sshManager: sshMgr)

        // 新架构协调器图装配
        let notifSvc = notificationService
        let swiftDataStore = store

        let contextFactory = TaskExecutionContextFactory(
            sshManager: sshMgr,
            toolRegistry: toolRegistry,
            memoryContextProvider: memorySvc,
            authService: authSvc,
            memoryService: memorySvc,
            store: swiftDataStore
        )

        let messageRepository = ChatMessageRepository(store: swiftDataStore)

        let tec = TaskExecutionCoordinator(
            taskQueue: PerServerTaskQueue(),
            stateStore: TaskStreamingStateStore(),
            lifecycleManager: TaskLifecycleManager(),
            messageRepository: messageRepository,
            contextFactory: contextFactory,
            aiService: aiSvc,
            contextBuilder: ctxBuilder,
            contextCompactor: ctxCompactor,
            keepAlive: BackgroundKeepAlive(),
            notificationService: notifSvc
        )
        self.taskExecutionCoordinator = tec
    }

    /// chatViewModelCache：按 server ID 缓存 ChatViewModel，返回时保持直连模式等状态。
    private var chatViewModelCache: [UUID: ChatViewModel] = [:]

    /// makeChatViewModel：获取或创建聊天页面所需的视图模型实例。
    /// 同一 server 复用已有实例，保持直连模式等会话状态。
    func makeChatViewModel(for server: Server) -> ChatViewModel {
        if let cached = chatViewModelCache[server.id] {
            return cached
        }
        let vm = ChatViewModel(
            server: server,
            store: store,
            sshManager: sshManager,
            aiService: aiService,
            toolRegistry: toolRegistry,
            keychainService: keychainService,
            taskCoordinator: taskExecutionCoordinator,
            memoryReader: memoryService,
            retainService: retainService,
            speechCoordinator: SpeechInputCoordinator(speechRecognitionService: speechRecognitionService),
            authService: authService,
            relayTokenService: relayTokenService,
            dlcInstaller: dlcInstaller
        )
        chatViewModelCache[server.id] = vm
        return vm
    }

    /// 查询已缓存的 ChatViewModel（只读，用于 Live Activity 快照聚合）。
    func cachedChatViewModel(for serverID: UUID) -> ChatViewModel? {
        chatViewModelCache[serverID]
    }

    /// removeChatViewModel：断开连接时清除缓存，下次进入重新创建。
    func removeChatViewModel(for serverID: UUID) {
        chatViewModelCache.removeValue(forKey: serverID)
    }

    /// makeServerListViewModel：构建服务器列表页面的视图模型实例。
    func makeServerListViewModel() -> ServerListViewModel {
        ServerListViewModel(store: store, keychainService: keychainService, relayTokenService: relayTokenService)
    }

    /// makeSSHKeyManagementViewModel：构建 SSH 密钥管理页面的视图模型实例。
    func makeSSHKeyManagementViewModel() -> SSHKeyManagementViewModel {
        SSHKeyManagementViewModel(store: store, keychainService: keychainService)
    }
}
