/// 文件说明：ChatView，负责聊天模块的界面展示与交互流程。
import SwiftUI

/// ChatView：负责界面渲染与用户交互响应。
struct ChatView: View {
    @State var viewModel: ChatViewModel
    var authService: AuthService
    var subscriptionService: SubscriptionService
    /// 断开连接后的回调（清除 ViewModel 缓存等）。
    var onDisconnect: ((UUID) -> Void)?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    /// 文件选择器显示状态。
    @State var isFilePickerPresented = false
    /// 超出大小限制的文件名列表（用于弹窗提示）。
    @State var oversizedFileAlert: [String]? = nil

    /// 健康检查任务是否处于活跃状态。
    @State private var healthCheckActive = false

    /// 用户是否处于消息列表底部附近，控制自动跟随滚动。
    @State private var isNearBottom: Bool = true

    /// 用户头像缓存。
    @State private var userAvatarImage: Image?

    /// 是否显示服务器信息页。
    @State private var showServerInfo = false

    var body: some View {
        applyPresentations(to: chatContent)
        .navigationTitle("")
        .navigationDestination(isPresented: $showServerInfo) {
            if let client: SSHClientProtocol = viewModel.sshManager.getClient(for: viewModel.serverID) {
                ServerInfoView(server: viewModel.server, sshClient: client)
            } else {
                ContentUnavailableView(
                    String(localized: "Disconnected", bundle: LanguageSettings.currentBundle),
                    systemImage: "wifi.slash"
                )
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .safeAreaInset(edge: .top, spacing: 0) {
            chatHeaderBar
        }
        .task {
            await viewModel.loadMessages()

            // SSH 连接已在网关层建立，检查状态
            _ = await viewModel.checkExistingConnection()

            // 若有活跃后台任务，注册 observer 接续流式状态
            if viewModel.hasActiveBackgroundTask {
                viewModel.attachObserver()
            }

            healthCheckActive = true
            await loadUserAvatar()
        }
        .onDisappear {
            healthCheckActive = false
            viewModel.detachObserver()
            // Shell channel 和直连会话保持活跃（系统返回手势不销毁）
            // 用户可在对话列表中滑动销毁，或手动退出直连模式
        }
        .task(id: healthCheckActive) {
            guard healthCheckActive else { return }
            await runHealthCheck()
        }
        .onChange(of: scenePhase) { _, newPhase in
            // 从后台恢复时立即触发探测式健康检查，不依赖可能过时的 isConnected flag
            if newPhase == .active && healthCheckActive {
                Task {
                    await viewModel.performForegroundResumeCheck()
                }
            }
        }
        .onChange(of: viewModel.speechState) {
            viewModel.syncSpeechState()
        }
    }

    // MARK: - 带进度动画的重连

    /// 显示进度动画并执行 SSH 重连，完成后淡入聊天界面。
    private func connectWithProgress() async {
        let progressVM = SSHConnectionProgressViewModel(server: viewModel.serverInfo)

        async let animationDone: Void = progressVM.startAnimation()
        viewModel.error = nil
        await viewModel.connect(isReconnection: true)

        if viewModel.isConnected {
            progressVM.reportConnectionResult(.success(()))
        } else {
            let error = viewModel.error ?? String(localized: "Connection failed", bundle: LanguageSettings.currentBundle)
            progressVM.reportConnectionResult(.failure(ConnectionProgressError.connectionFailed(error)))
        }

        _ = await animationDone
        await progressVM.waitForCompletion()
    }

    // MARK: - 聊天主内容

    private var chatContent: some View {
        VStack(spacing: 0) {
            // 连接状态横幅
            ConnectionBannerView(
                isReconnecting: isReconnecting,
                isConnected: viewModel.isConnected,
                onReconnect: {
                    Task { await attemptReconnect() }
                }
            )
            .animation(.easeInOut(duration: 0.25), value: isReconnecting)
            .animation(.easeInOut(duration: 0.25), value: viewModel.isConnected)

            // Messages
            ChatMessageListView(
                viewModel: viewModel,
                userAvatarImage: userAvatarImage,
                isNearBottom: $isNearBottom,
                onServerAvatarTap: { showServerInfo = true }
            )

            Divider()

            // Input bar
                ChatInputBar(
                    text: $viewModel.inputText,
                    isConnected: viewModel.isConnected,
                    isContextCompressing: viewModel.isContextCompressing,
                    attachments: viewModel.attachments,
                onSend: {
                    isNearBottom = true
                    viewModel.sendMessage()
                },
                    onPickFile: { isFilePickerPresented = true },
                    onRemoveAttachment: { viewModel.removeAttachment($0) },
                    presentationState: viewModel.directModePresentation,
                    isConnectingToAgent: viewModel.directSessionCoordinator.isConnectingToAgent,
                    hasConfigData: !viewModel.directSessionCoordinator.state.metadata.configOptions.isEmpty || !viewModel.directSessionCoordinator.state.metadata.commands.isEmpty || viewModel.directSessionCoordinator.state.metadata.models != nil || viewModel.directSessionCoordinator.state.metadata.modes != nil,
                    onConfigTap: { viewModel.showDirectModeConfigSheet = true },
                    onCancelConnect: { viewModel.directSessionCoordinator.cancelConnecting() },
                isSpeechAvailable: viewModel.isSpeechAvailable,
                speechState: viewModel.speechState,
                hideAttachments: false,
                onMicTap: { Task { await viewModel.toggleSpeechRecognition() } }
            )
        }
    }

    // MARK: - 自定义导航栏

    /// 自定义导航栏 header，替代系统 toolbar 实现左对齐大标题。
    private var chatHeaderBar: some View {
        HStack(alignment: .center, spacing: 14) {
            // 返回按钮：返回服务器列表，保持当前连接/模式不变
            Button {
                dismiss()
            } label: {
                    Image(systemName: "chevron.left")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(
                        viewModel.directModePresentation.isActive
                            ? viewModel.directModePresentation.modeColors.accentColor
                            : .blue
                    )
            }

            // 标题 + 副标题（点击进入服务器信息页）
            Button {
                showServerInfo = true
            } label: {
                ChatNavigationTitleView(
                    title: viewModel.navigationTitle,
                    isConnected: viewModel.isConnected,
                    isReconnecting: viewModel.isReconnecting,
                    countryCode: viewModel.server.countryCode,
                    presentationState: viewModel.directModePresentation
                )
            }
            .buttonStyle(.plain)

            Spacer()

            // 右侧按钮
            if viewModel.directModePresentation.isActive {
                // 直连模式：退出直连，回到普通 AI 模式
                Button {
                    Task { await viewModel.directSessionCoordinator.disconnect(messages: viewModel.messages) }
                } label: {
                    Image(systemName: "escape")
                        .foregroundStyle(viewModel.directModePresentation.modeColors.accentColor)
                        .shadow(color: viewModel.directModePresentation.modeColors.accentColor.opacity(0.6), radius: 4)
                }
            } else {
                // 普通模式：断开 SSH 连接并返回
                Button {
                    Task {
                        let sid = viewModel.serverID
                        await viewModel.disconnectAndCleanup()
                        onDisconnect?(sid)
                        dismiss()
                    }
                } label: {
                    Image(systemName: "bolt.slash")
                        .foregroundStyle(.green)
                        .shadow(color: .green.opacity(0.6), radius: 4)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    // MARK: - 重连

    /// 带进度动画的手动重连（横幅重连按钮）。
    private func attemptReconnect() async {
        guard !isReconnecting else { return }
        viewModel.isReconnecting = true
        await connectWithProgress()
        viewModel.isReconnecting = false
    }

    // MARK: - 健康检查

    /// 每 60 秒轮询一次连接状态，断开时自动尝试重连。
    private func runHealthCheck() async {
        while !Task.isCancelled && healthCheckActive {
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled && healthCheckActive else { break }

            // 仅在本地标记「已连接」时检查底层真实状态
            if viewModel.isConnected {
                await viewModel.performHealthCheck()
            }
        }
    }

    // MARK: - 用户头像加载

    /// 异步加载用户头像，使用 AuthService 缓存避免重复网络请求。
    private func loadUserAvatar() async {
        guard authService.isLoggedIn else { return }
        if let data = await authService.loadAvatarDataIfNeeded(),
           let img = ImageUtils.makeSwiftUIImage(from: data) {
            userAvatarImage = img
        }
    }

    private var isReconnecting: Bool {
        viewModel.isReconnecting
    }
}
