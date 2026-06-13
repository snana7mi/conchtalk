//
//  ConchTalkApp.swift
//  ConchTalk
//
//  Created by cheung on 2026/02/16.
//

/// 文件说明：ConchTalkApp，应用入口，负责初始化依赖并组织主界面导航。
import SwiftUI
import SwiftData
import RevenueCat

enum AppTab: Hashable {
    case servers
    case settings
}

/// 连接网关状态。
enum ConnectionGatewayState: Equatable {
    case idle
    case connecting(serverID: UUID)
    case failed(serverID: UUID, message: String)
}

/// ConchTalkApp：应用入口与全局导航的组装点。
@main
struct ConchTalkApp: App {
    @State private var container: DependencyContainer?
    @State private var selectedServer: Server?
    @State private var selectedLanguage = LanguageSettings.load().language
    @State private var selectedTab: AppTab = .servers
    @State private var settingsHasUnsavedChanges = false
    @State private var showUnsavedChangesAlert = false
    @State private var pendingTab: AppTab?
    @State private var triggerSettingsSave = false
    @Environment(\.scenePhase) private var scenePhase

    // 连接网关
    @State private var gatewayState: ConnectionGatewayState = .idle
    @State private var connectTask: Task<Void, Never>?
    @State private var gatewayGeneration: UInt = 0
    @State private var gatewayProgressVM: SSHConnectionProgressViewModel?
    /// 主机密钥不匹配时，记录待重连的服务器（用于"信任新密钥"后重试）。
    @State private var hostKeyMismatchServer: Server?

    // 过期服务器清理提示
    @State private var expiredServerToast: String?

    // (云同步在 .task 中根据 tier 自动开启)

    /// 根据用户选择返回对应的 Locale，跟随系统时返回 nil。
    private var overrideLocale: Locale? {
        selectedLanguage.locale
    }

    var body: some Scene {
        WindowGroup {
            if let container {
                mainContent(container)
            } else {
                // 启动屏：依赖容器异步加载中
                splashView
            }
        }
    }

    /// 启动屏（依赖容器加载期间展示）。
    private var splashView: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "terminal.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                ProgressView()
            }
        }
        .task {
            let c = await DependencyContainer.create()
            container = c
        }
    }

    /// 主界面（依赖容器就绪后展示）。
    @ViewBuilder
    private func mainContent(_ container: DependencyContainer) -> some View {
        ZStack {
            TabView(selection: Binding(
                get: { selectedTab },
                set: { newTab in
                    if selectedTab == .settings && newTab != .settings && settingsHasUnsavedChanges {
                        pendingTab = newTab
                        showUnsavedChangesAlert = true
                    } else {
                        selectedTab = newTab
                    }
                }
            )) {
                Tab(String(localized: "Servers", bundle: LanguageSettings.currentBundle), systemImage: "server.rack", value: .servers) {
                    NavigationStack {
                        ServerListView(
                            viewModel: container.makeServerListViewModel(),
                            sshManager: container.sshManager,
                            keychainService: container.keychainService,
                            onSelectServer: { server in
                                connectAndNavigate(to: server)
                            },
                            onDisconnect: { serverID in
                                Task {
                                    await container.taskExecutionCoordinator.cancelTasks(forServer: serverID)
                                    await container.sshManager.disconnect(from: serverID)
                                    container.removeChatViewModel(for: serverID)
                                }
                            }
                        )
                        .navigationDestination(item: $selectedServer) { server in
                            ChatView(
                                viewModel: container.makeChatViewModel(for: server),
                                authService: container.authService,
                                subscriptionService: container.subscriptionService,
                                onDisconnect: { serverID in
                                    container.removeChatViewModel(for: serverID)
                                }
                            )
                        }
                    }
                }
                Tab(String(localized: "Settings", bundle: LanguageSettings.currentBundle), systemImage: "gear", value: .settings) {
                    NavigationStack {
                        SettingsView(
                            selectedLanguage: $selectedLanguage,
                            authService: container.authService,
                            sshKeyManagementViewModel: container.makeSSHKeyManagementViewModel(),
                            syncService: container.syncService,
                            subscriptionService: container.subscriptionService,
                            reportUnsavedChanges: $settingsHasUnsavedChanges,
                            triggerSave: $triggerSettingsSave
                        )
                    }
                }
            }

            // 连接网关全屏 Loading 覆盖层
            if case .connecting = gatewayState, let progressVM = gatewayProgressVM {
                ZStack {
                    SSHConnectionProgressView(viewModel: progressVM)
                        .transition(.opacity)

                    VStack {
                        HStack {
                            Spacer()
                            Button {
                                cancelGateway()
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.title2)
                                    .foregroundStyle(.secondary)
                            }
                            .padding()
                        }
                        Spacer()
                    }
                }
            }
        }
        .alert("Unsaved Changes", isPresented: $showUnsavedChangesAlert) {
            Button("Save") {
                triggerSettingsSave = true
                if let tab = pendingTab {
                    selectedTab = tab
                    pendingTab = nil
                }
            }
            Button("Cancel", role: .cancel) {
                pendingTab = nil
            }
        } message: {
            Text("You have unsaved settings changes.")
        }
        .alert(
            "Connection Failed",
            isPresented: Binding(
                get: { if case .failed = gatewayState { return true } else { return false } },
                set: { if !$0 {
                    gatewayState = .idle
                    hostKeyMismatchServer = nil
                }}
            )
        ) {
            if let server = hostKeyMismatchServer {
                Button(String(localized: "Trust New Key & Reconnect", bundle: LanguageSettings.currentBundle)) {
                    let s = server
                    hostKeyMismatchServer = nil
                    gatewayState = .idle
                    Task {
                        await KnownHostsStore().remove(host: s.host, port: s.port)
                        connectAndNavigate(to: s)
                    }
                }
                Button(String(localized: "Cancel", bundle: LanguageSettings.currentBundle), role: .cancel) {
                    gatewayState = .idle
                    hostKeyMismatchServer = nil
                }
            } else {
                Button("OK", role: .cancel) { gatewayState = .idle }
            }
        } message: {
            if case .failed(_, let message) = gatewayState {
                Text(message)
            }
        }
        .environment(\.locale, overrideLocale ?? .autoupdatingCurrent)
        .task {
            await SSHKeyMigrationService.migrateIfNeeded(
                store: container.store,
                keychainService: container.keychainService
            )
            // 凭据条目 accessibility 一次性迁移（.task 在前台首帧后执行，设备必然解锁，
            // 满足 SecItemUpdate 重新加密的前置条件）
            container.keychainService.migrateCredentialAccessibilityIfNeeded()
            container.notificationService.requestAuthorization()
            // 冷启动恢复：已登录用户拉取最新 tier（重装后 UserDefaults 丢失，依赖此处刷新）
            let wasLoggedInAtLaunch = container.authService.isLoggedIn
            print("[App] Launch: isLoggedIn=\(wasLoggedInAtLaunch), syncEnabled=\(SyncState.isEnabled)")
            if wasLoggedInAtLaunch {
                do {
                    try await container.authService.fetchAccount()
                    print("[App] fetchAccount succeeded: tier=\(container.authService.currentUser?.tier ?? "nil")")
                } catch {
                    print("[App] fetchAccount failed: \(error), isLoggedIn now=\(container.authService.isLoggedIn)")
                }
            }
            // RevenueCat 配置（使用缓存的 appleSub 作为用户标识）
            // API Key 从 Info.plist 的 REVENUECAT_API_KEY 读取（不硬编码，项目为开源仓库）
            if let rcAPIKey = Bundle.main.object(forInfoDictionaryKey: "REVENUECAT_API_KEY") as? String,
               !rcAPIKey.isEmpty {
                Purchases.logLevel = .warn
                if let appleSub = container.authService.cachedAppleSub {
                    Purchases.configure(withAPIKey: rcAPIKey, appUserID: appleSub)
                } else {
                    // cachedAppleSub 可能因重装丢失，fetchAccount 已补回
                    Purchases.configure(withAPIKey: rcAPIKey)
                    if let appleSub = container.authService.cachedAppleSub {
                        _ = try? await Purchases.shared.logIn(appleSub)
                    }
                }
                // 仅在 RC 配置成功后才开始监听
                container.subscriptionService.startListening()
            }
            // 付费用户自动开启云同步（同一用户主动关闭过则不再自动开启）
            // 放在 fetchAccount 之后，确保 currentUser.tier 已从后端刷新
            if container.authService.isLoggedIn && !SyncState.isEnabled {
                let tier = container.authService.currentUser?.tier
                    ?? UserDefaults.standard.string(forKey: "AuthService.cachedTier")
                let userId = container.authService.currentUser?.id
                    ?? UserDefaults.standard.string(forKey: "AuthService.cachedUserID")
                let wasDisabledByThisUser = userId != nil && SyncState.disabledByUserID == userId
                print("[App] Sync auto-enable check: tier=\(tier ?? "nil"), wasDisabled=\(wasDisabledByThisUser)")
                if tier == "paid" && !wasDisabledByThisUser {
                    SyncState.isEnabled = true
                    print("[App] Sync auto-enabled, starting initial sync...")
                    await container.syncService.sync()
                    print("[App] Initial sync completed")
                }
            }
            // 已登录且同步已开启但本次启动尚未同步过（如正常启动非重装场景），也执行一次拉取
            if SyncState.isEnabled && container.authService.isLoggedIn {
                if SyncState.lastPulledSeq == 0 {
                    print("[App] Sync enabled but never pulled, starting recovery sync...")
                    await container.syncService.sync()
                    print("[App] Recovery sync completed")
                }
            }
            // 启动时检查并清理过期服务器
            do {
                let expired = try await container.store.fetchExpiredServers()
                if !expired.isEmpty {
                    var deletedNames: [String] = []
                    for server in expired {
                        // 清理 Keychain 密码和已知主机指纹
                        try? container.keychainService.deletePassword(forServer: server.id)
                        await KnownHostsStore().remove(host: server.host, port: server.port)
                        try await container.store.deleteServer(server.id)
                        deletedNames.append(server.name)
                    }
                    let names = deletedNames.joined(separator: ", ")
                    expiredServerToast = names
                }
            } catch {
                print("[App] Failed to check expired servers: \(error)")
            }
            // 修复冷启动竞态：App 从通知启动时，delegate 回调可能先于 onChange 绑定，
            // 在此消费已存在的 pendingNavigation。
            if let nav = container.notificationService.pendingNavigation {
                container.notificationService.pendingNavigation = nil
                handleNotificationNavigation(serverID: nav.serverID)
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            container.taskExecutionCoordinator.isAppInForeground = (newPhase == .active)
            if newPhase == .active {
                container.taskExecutionCoordinator.onForegroundResume()
                // 回前台：停止轮询，结束 Live Activity（无活跃 AI 任务时）
                container.metricsPoller.stop()
                if container.taskExecutionCoordinator.activeTaskServerIDs.isEmpty {
                    container.taskExecutionCoordinator.liveActivity.endGlobalActivity()
                }
                Task {
                    let disconnectedIDs = await container.sshManager.findDisconnectedServers()
                    if !disconnectedIDs.isEmpty {
                        await handleBackgroundDisconnection(serverIDs: disconnectedIDs)
                    }
                }
            } else if newPhase == .background {
                container.taskExecutionCoordinator.beginBackgroundKeepAlive()
                let hasSSH = !container.sshManager.activeConnectionIDs.isEmpty
                if hasSSH {
                    container.taskExecutionCoordinator.liveActivity.startGlobalActivity()
                    container.metricsPoller.start()
                    container.metricsPoller.onMetricsUpdated = {
                        await self.updateLiveActivitySnapshot()
                    }
                    Task {
                        await self.updateLiveActivitySnapshot()
                    }
                }
                // 云同步：进后台时触发
                let syncService = container.syncService
                Task {
                    await syncService.sync()
                }
            }
        }
        .onChange(of: container.notificationService.pendingNavigation) { _, nav in
            guard let nav else { return }
            container.notificationService.pendingNavigation = nil
            handleNotificationNavigation(serverID: nav.serverID)
        }
        .overlay(alignment: .top) {
            if let toast = expiredServerToast {
                HStack(spacing: 8) {
                    Image(systemName: "trash.circle.fill")
                        .foregroundStyle(.red)
                    Text(String(localized: "\(toast) expired and removed", bundle: LanguageSettings.currentBundle))
                        .font(.subheadline)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
                .onAppear {
                    Task {
                        try? await Task.sleep(for: .seconds(3))
                        withAnimation { expiredServerToast = nil }
                    }
                }
            }
        }
        .animation(.easeInOut, value: expiredServerToast)
        .modelContainer(container.modelContainer)
    }

    // MARK: - Live Activity Snapshot

    private func updateLiveActivitySnapshot() async {
        guard let container else { return }
        let connectedServers = container.sshManager.connectedServerNames()
        let connectionTimes = container.sshManager.connectionStartTimes()
        var snapshots: [ServerSnapshot] = []

        for (serverID, serverName) in connectedServers {
            let lastReply: String
            if let reply = try? await container.store.fetchLastAssistantMessage(forServer: serverID) {
                lastReply = reply
            } else {
                lastReply = ""
            }
            let metrics = container.metricsPoller.metrics(for: serverID)
            let connectionSecs: Int
            if let startTime = connectionTimes[serverID] {
                connectionSecs = Int(Date().timeIntervalSince(startTime))
            } else {
                connectionSecs = 0
            }

            snapshots.append(ServerSnapshot(
                serverID: serverID,
                serverName: serverName,
                lastReply: lastReply,
                cpuUsage: metrics?.cpuUsage ?? 0,
                memoryUsage: metrics?.memoryUsage ?? 0,
                connectionSeconds: connectionSecs,
                hasActiveTask: container.taskExecutionCoordinator.hasActiveTask(for: serverID)
            ))
        }

        container.taskExecutionCoordinator.liveActivity.updateServers(snapshots, force: true)
    }

    // MARK: - 连接网关

    /// 连接到服务器并导航。已连接时直接跳转，否则全屏 Loading 后跳转。
    private func connectAndNavigate(to server: Server) {
        guard let container else { return }
        connectTask?.cancel()
        connectTask = nil
        if case .connecting = gatewayState { gatewayState = .idle }

        gatewayGeneration &+= 1
        let myGeneration = gatewayGeneration

        let sshManager = container.sshManager
        let keychainService = container.keychainService

        connectTask = Task {
            // 快速路径：已连接
            let isAlive = await sshManager.isConnected(serverID: server.id)
            if isAlive {
                guard myGeneration == gatewayGeneration else { return }
                gatewayState = .idle
                let vm = container.makeChatViewModel(for: server)
                await vm.loadMessages()
                vm.isConnected = true
                selectedServer = server
                return
            }

            // 显示连接进度
            guard myGeneration == gatewayGeneration else { return }
            let progressVM = SSHConnectionProgressViewModel(server: server)
            gatewayProgressVM = progressVM
            gatewayState = .connecting(serverID: server.id)

            // 并发：动画 + 真实连接
            async let animationDone: Void = progressVM.startAnimation()

            var connectError: String?
            do {
                try Task.checkCancellation()
                var password: String? = nil
                if case .password = server.authMethod {
                    password = try keychainService.getPassword(forServer: server.id)
                }
                // currentUser 尚未加载时回退到本地缓存的 tier，避免 session restore 期间误判
                let userTier = container.authService.currentUser?.tier
                    ?? UserDefaults.standard.string(forKey: "AuthService.cachedTier")
                    ?? "free"
                try await sshManager.ensureConnected(to: server, password: password, keychainService: keychainService, userTier: userTier)
                try Task.checkCancellation()
                progressVM.reportConnectionResult(.success(()))
            } catch is CancellationError {
                return
            } catch let sshError as SSHError {
                connectError = sshError.localizedDescription
                // 主机密钥不匹配时记录服务器，以便用户选择信任新密钥后重连
                if case .hostKeyMismatch = sshError {
                    hostKeyMismatchServer = server
                }
                progressVM.reportConnectionResult(.failure(ConnectionProgressError.connectionFailed(sshError.localizedDescription)))
            } catch {
                connectError = error.localizedDescription
                progressVM.reportConnectionResult(.failure(ConnectionProgressError.connectionFailed(error.localizedDescription)))
            }

            _ = await animationDone
            await progressVM.waitForCompletion()

            guard myGeneration == gatewayGeneration else { return }

            if let errorMsg = connectError {
                withAnimation(.easeInOut(duration: 0.3)) {
                    gatewayState = .failed(serverID: server.id, message: errorMsg)
                }
            } else {
                withAnimation(.easeInOut(duration: 0.3)) {
                    gatewayState = .idle
                }
                // 预加载消息并标记已连接，避免 ConnectionBannerView 闪现导致布局偏移破坏滚动锚点
                let vm = container.makeChatViewModel(for: server)
                await vm.loadMessages()
                vm.isConnected = true
                selectedServer = server
            }
        }
    }

    /// 处理通知点击导航：跳转到对应服务器的聊天页面。
    private func handleNotificationNavigation(serverID: UUID) {
        guard let container else { return }
        // 尊重未保存设置保护
        if selectedTab == .settings && settingsHasUnsavedChanges {
            triggerSettingsSave = true
        }
        selectedTab = .servers

        Task {
            let servers = try? await container.store.fetchServers()
            guard let server = servers?.first(where: { $0.id == serverID }) else { return }
            connectAndNavigate(to: server)
        }
    }

    // MARK: - 后台断连处理

    /// 后台恢复时处理断连：当前聊天服务器保留给 ChatView 原地重连，其余服务器清理连接。
    private func handleBackgroundDisconnection(serverIDs: [UUID]) async {
        guard let container else { return }
        let plan = BackgroundDisconnectionPlan(
            disconnectedServerIDs: serverIDs,
            currentChatServerID: selectedServer?.id
        )
        print(
            "[App] Background disconnection detected: servers=\(serverIDs.map(\.uuidString)), " +
            "currentChatServer=\(plan.reconnectInPlaceServerID?.uuidString ?? "nil"), " +
            "cleanupServers=\(plan.cleanupServerIDs.map(\.uuidString))"
        )

        // 当前正在查看的服务器：只取消后台任务，不断开 SSH、不重置导航。
        // 断线消息统一由 ChatView 的健康检查路径写入，避免重复提示。
        if let reconnectServerID = plan.reconnectInPlaceServerID {
            print("[App] Current server disconnected, staying in place for auto-reconnect")
            _ = await container.taskExecutionCoordinator.cancelTasks(forServer: reconnectServerID)
        }

        // 其余断连服务器：完整清理（取消任务、断开 SSH）
        if !plan.cleanupServerIDs.isEmpty {
            await cleanupDisconnectedServers(serverIDs: plan.cleanupServerIDs, shouldResetNavigation: false)
        }
    }

    private func cleanupDisconnectedServers(serverIDs: [UUID], shouldResetNavigation: Bool) async {
        guard let container else { return }
        let timestamp = Date.now.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(LanguageSettings.currentLocale))
        let disconnectContent = String(localized: "Connection lost, please reconnect to server", bundle: LanguageSettings.currentBundle) + " (\(timestamp))"

        for serverID in serverIDs {
            // 1. 取消该服务器上的所有 AI 任务
            let activeServerIDs = await container.taskExecutionCoordinator.cancelTasks(forServer: serverID)

            // 2. 仅向有活跃任务的服务器插入断连消息。
            //    必须每台新建独立 Message（独立 UUID）：addMessage 按全局 ID 幂等去重，
            //    若复用同一个 disconnectMsg，多台同时断连时只有第一台能写入。
            for sid in activeServerIDs {
                let disconnectMsg = Message(
                    role: .system,
                    content: disconnectContent,
                    systemMessageType: .connectionLost
                )
                try? await container.store.addMessage(disconnectMsg, toServer: sid)
            }

            // 3. 清理 SSH 连接
            await container.sshManager.disconnect(from: serverID)
        }

        if shouldResetNavigation,
           let current = selectedServer,
           serverIDs.contains(current.id) {
            selectedServer = nil
        }
    }

    private func cancelGateway() {
        let cancelledState = gatewayState
        gatewayGeneration &+= 1
        connectTask?.cancel()
        connectTask = nil
        gatewayState = .idle

        // 断开可能已建立的 SSH 连接
        if case .connecting(let serverID) = cancelledState {
            Task {
                await container?.sshManager.disconnect(from: serverID)
            }
        }
    }
}
