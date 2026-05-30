/// 文件说明：ChatViewModel，负责聊天页面状态管理、SSH 会话联动与 AI 对话编排。
import SwiftUI
import SwiftData
@preconcurrency import Citadel

/// ChatViewModel：
/// 作为 Chat 页面状态中枢，负责管理消息与输入状态、协调 SSH 连接，
/// 并驱动 AI/工具调用流程将中间结果实时回写到界面。
/// AI 任务生命周期由 TaskExecutionCoordinator 持有，确保离开页面后任务继续运行。

@MainActor
@Observable
final class ChatViewModel {
    var messages: [Message] = [] {
        didSet { derivedState = ChatDerivedState(messages: messages) }
    }
    /// 缓存的派生状态，由 messages 的 didSet 自动同步。
    private(set) var derivedState: ChatDerivedState = .empty
    /// 过滤掉 aiContext 系统消息后的展示列表，避免在 ForEach 中内联 filter 导致身份不稳定。
    var displayMessages: [Message] { derivedState.displayMessages }
    var inputText: String = ""
    var isProcessing: Bool = false
    var isConnected: Bool = false
    var isReconnecting: Bool = false
    var error: String?
    var pendingToolCall: ToolCall?
    var showConfirmation: Bool = false
    var isContextCompressing: Bool = false
    var activeReasoningText: String = ""
    var activeContentText: String = ""
    var isStreaming: Bool = false
    var isReasoningActive: Bool = false
    /// 流式滚动触发计数器，每次流式回调递增，供 ScrollTriggerView 监听以触发滚动。
    var streamingScrollTrigger: UInt = 0
    /// 直连模式流式滚动节流任务，避免每个 chunk 都触发一次 UI 滚动更新。
    var directStreamScrollTask: Task<Void, Never>?
    /// 工具执行过程中的实时输出文本，供 UI 在加载气泡中展示命令执行进度。
    /// `nil` = 无工具执行，`""` = 工具已启动但尚无输出，非空 = 有输出内容。
    var liveToolOutput: String? = nil
    /// 编码代理流式事件（已解析）。
    var agentStreamEvents: [AgentStreamEvent] = []
    /// 是否正在执行编码代理。
    var isAgentExecuting: Bool = false
    /// 用户选中的待上传附件列表（UI 展示用）。
    var attachments: [FileAttachment] = []
    /// 已发送但尚未上传完成的附件，跨消息保持可用直到上传成功。
    var pendingAttachments: [FileAttachment] = []
    /// 防止 syncAfterTaskCompletion 被并发重入调用。
    var isSyncingAfterCompletion = false
    /// 当前处于排队等待状态的消息 ID 集合（显示为半透明虚幻样式）。
    var queuedMessageIDs: Set<UUID> = []
    /// 延迟 enqueue 任务（等待全量历史加载），disconnect 时需取消。
    var deferredEnqueueTask: Task<Void, Never>?
    /// Paywall 弹出状态（连接数限制触发时显示）。
    var showPaywall: Bool = false

    // MARK: - 直连模式协调器

    /// 直连 session 协调器，负责逻辑层编排。
    var directSessionCoordinator: DirectSessionCoordinator

    /// 直连 session 事件消费任务。
    var directEventTask: Task<Void, Never>?

    /// Agent 选择器与目录浏览器协调器。
    var agentPicker: AgentPickerCoordinator

    /// 直连模式配置面板显示状态（纯 UI 状态）。
    var showDirectModeConfigSheet = false

    /// 直连模式统一展示状态，供页面与组件消费。
    var directModePresentation: DirectModePresentationState {
        .build(from: directSessionCoordinator.state)
    }

    // MARK: - 语音识别（转发到 SpeechInputCoordinator）

    var isSpeechAvailable: Bool {
        guard !directModePresentation.isActive else { return false }
        return speechCoordinator.isAvailable
    }

    var isSpeechListening: Bool { speechCoordinator.isListening }

    var speechState: SpeechRecognitionState { speechCoordinator.state }

    func toggleSpeechRecognition() async {
        if let newText = await speechCoordinator.toggle(currentText: inputText) {
            inputText = newText
        }
    }

    func syncSpeechState() {
        speechCoordinator.syncPartialText(to: &inputText)
    }

    /// 供进度视图获取服务器信息。
    var serverInfo: Server { server }

    var server: Server
    /// 服务器 ID（唯一键，替代旧的 conversationID）。
    var serverID: UUID { server.id }
    let store: SwiftDataStore
    let sshManager: SSHSessionManager
    let aiService: AIServiceProtocol
    private let toolRegistry: ToolRegistryProtocol
    let keychainService: KeychainServiceProtocol
    let taskCoordinator: TaskExecutionCoordinator
    private let memoryReader: MemoryReader
    private let retainService: RetainService
    let speechCoordinator: SpeechInputCoordinator
    let authService: AuthServiceProtocol

    /// 初始化聊天视图模型并注入业务依赖。
    init(server: Server, store: SwiftDataStore, sshManager: SSHSessionManager, aiService: AIServiceProtocol, toolRegistry: ToolRegistryProtocol, keychainService: KeychainServiceProtocol, taskCoordinator: TaskExecutionCoordinator, memoryReader: MemoryReader, retainService: RetainService, speechCoordinator: SpeechInputCoordinator, authService: AuthServiceProtocol) {
        self.server = server
        self.store = store
        self.sshManager = sshManager
        self.aiService = aiService
        self.toolRegistry = toolRegistry
        self.keychainService = keychainService
        self.taskCoordinator = taskCoordinator
        self.memoryReader = memoryReader
        self.retainService = retainService
        self.speechCoordinator = speechCoordinator
        self.authService = authService
        let iconData = FlagImageRenderer.resolveServerIconData(server: server, size: 300)
        self.serverIconData = iconData
        self.serverIconImage = iconData.flatMap { ImageUtils.makeSwiftUIImage(from: $0) }

        self.directSessionCoordinator = DirectSessionCoordinator()
        self.agentPicker = Self.makeAgentPickerCoordinator(
            sshManager: sshManager,
            server: server,
            taskCoordinator: taskCoordinator
        )
        bindCoordinators()
        startDirectSessionEventConsumption()
    }

    /// VM 由 DependencyContainer 按 serverID 缓存，移除时仅从字典删除、不主动 cancel 这些长存任务。
    /// directEventTask 全程无人取消，普通模式断开后会泄漏。
    /// deinit 作为安全网，统一取消所有长存任务。用 isolated deinit 在 MainActor 上执行，
    /// 以合法访问 MainActor 隔离的 Task 属性（普通 nonisolated deinit 无法访问它们）。
    isolated deinit {
        directEventTask?.cancel()
        deferredEnqueueTask?.cancel()
        directStreamScrollTask?.cancel()
    }

    /// 当前会话是否有活跃的后台 AI 任务。
    var hasActiveBackgroundTask: Bool {
        taskCoordinator.hasActiveTask(for: serverID)
    }

    // MARK: - Context Break

    /// 最后一条 contextBreak 消息在 messages 数组中的索引（转发 derivedState 缓存）。
    var lastContextBreakIndex: Int? { derivedState.lastContextBreakIndex }

    /// break 之前的消息 ID 集合（用于 UI 透明度判断），O(1) 查找（转发 derivedState 缓存）。
    var messageIDsBeforeBreak: Set<UUID> { derivedState.messageIDsBeforeBreak }

    /// 是否可以触发 context break
    var canTriggerContextBreak: Bool {
        return !isProcessing && queuedMessageIDs.isEmpty
    }

    /// 触发上下文断点：将最近消息写入 Memory，插入分隔消息并持久化。
    func triggerContextBreak() async {
        guard canTriggerContextBreak else { return }

        // 1. 异步刷入 Memory（只处理上次 break 到现在的消息）
        let messagesForRetain: [Message]
        if let breakIndex = lastContextBreakIndex {
            messagesForRetain = Array(messages.suffix(from: messages.index(after: breakIndex)))
        } else {
            messagesForRetain = messages
        }

        let serverID = self.serverID
        let retainService = self.retainService
        Task.detached {
            print("[ContextBreak] Memory retain started for server \(serverID)")
            await retainService.retain(serverID: serverID, recentMessages: messagesForRetain)
            print("[ContextBreak] Memory retain completed for server \(serverID)")
        }

        // 2. 插入 contextBreak 分隔消息
        let breakMessage = Message(
            role: .system,
            content: "",
            systemMessageType: .contextBreak
        )
        messages.append(breakMessage)

        // 3. 持久化
        try? await store.addMessage(breakMessage, toServer: serverID)

        // 4. 触觉反馈
        HapticFeedback.contextBreak()

        // 5. 直连模式切换到新的 ACP session
        if directModePresentation.isActive {
            _ = await directSessionCoordinator.rotateAfterContextBreak()
        }
    }

    /// 服务器图标数据（初始化时一次性解析并缓存），用于通知等场景。
    let serverIconData: Data?
    /// 服务器图标 SwiftUI Image（初始化时一次性解码并缓存），用于聊天气泡头像显示。
    let serverIconImage: Image?

    /// 分页大小。
    private let pageSize = 100
    /// 是否还有更早的消息可加载。
    private(set) var hasOlderMessages = true
    /// 是否正在加载更早的消息（防止并发加载）。
    private(set) var isLoadingOlderMessages = false
    /// prepend 标记，供 View 层区分 append/prepend 滚动行为。
    private(set) var isPrependingMessages = false

    /// 加载当前服务器消息；若无历史消息则写入初始系统消息。
    /// 加载完成后检查是否有活跃后台任务，若有则恢复 UI 状态。
    func loadMessages() async {
        do {
            let loaded = try await store.fetchRecentMessages(forServer: serverID, limit: pageSize)
            hasOlderMessages = loaded.count >= pageSize
            if loaded.isEmpty {
                let systemMsg = Message(role: .system, content: String(localized: "Connected to \(server.name) (\(server.host))", bundle: LanguageSettings.currentBundle), systemMessageType: .info)
                try await store.addMessage(systemMsg, toServer: serverID)
                messages = [systemMsg]
            } else {
                messages = loaded
                // 检测并恢复异常中断的直连模式（App 被杀时 exitDirectMode 未执行）
                await recoverOrphanedDirectModeState()
            }
        } catch {
            self.error = error.localizedDescription
        }

        // 恢复后台任务的 UI 状态
        if taskCoordinator.hasActiveTask(for: serverID) {
            isProcessing = true
            // 添加 loading 指示器（若消息列表末尾不是 loading）
            if !messages.contains(where: { $0.isLoading }) {
                let loadingMsg = Message(id: UUID(), role: .assistant, content: "", isLoading: true)
                messages.append(loadingMsg)
            }
        }
    }

    // MARK: - 分页加载

    /// 加载更早的消息（向上翻页）。
    func loadOlderMessages() async {
        guard hasOlderMessages, !isLoadingOlderMessages else { return }
        guard let firstMessage = messages.first else { return }

        isLoadingOlderMessages = true
        defer { isLoadingOlderMessages = false }

        do {
            let older = try await store.fetchOlderMessages(
                forServer: serverID,
                limit: pageSize,
                beforeTimestamp: firstMessage.timestamp,
                beforeID: firstMessage.id
            )

            if older.isEmpty {
                hasOlderMessages = false
                return
            }

            isPrependingMessages = true
            messages.insert(contentsOf: older, at: 0)
            isPrependingMessages = false

            if older.count < pageSize {
                hasOlderMessages = false
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// AI 任务启动前确保完整对话历史已加载。
    /// - Returns: 是否成功加载了全部历史（`false` 表示中途出错，历史不完整）。
    @discardableResult
    func ensureFullHistoryLoaded() async -> Bool {
        // 等待进行中的分页加载完成，避免并发 prepend
        while isLoadingOlderMessages {
            try? await Task.sleep(for: .milliseconds(50))
        }
        isLoadingOlderMessages = true
        defer { isLoadingOlderMessages = false }

        while hasOlderMessages {
            guard let firstMessage = messages.first else { break }
            do {
                let older = try await store.fetchOlderMessages(
                    forServer: serverID,
                    limit: pageSize,
                    beforeTimestamp: firstMessage.timestamp,
                    beforeID: firstMessage.id
                )
                if older.isEmpty {
                    hasOlderMessages = false
                    break
                }
                messages.insert(contentsOf: older, at: 0)
                if older.count < pageSize {
                    hasOlderMessages = false
                }
            } catch {
                return false
            }
        }
        return true
    }

    // MARK: - 直连模式恢复

    /// 检测 App 异常退出导致的孤立直连模式状态，补注系统消息通知 AI。
    /// 逆序扫描消息，找到最后一条 suggest_agent_connection 的 "Session paused" 结果，
    /// 检查其后是否有退出通知（"[Context] Direct session" 摘要或 "returned to ConchTalk" 系统消息）。
    private func recoverOrphanedDirectModeState() async {
        // 找到最后一条进入直连模式的 tool result
        guard let lastEntryIndex = messages.lastIndex(where: {
            $0.role == .command
            && $0.toolCall?.toolName == "suggest_agent_connection"
            && $0.toolOutput?.contains("Session paused") == true
        }) else { return }

        // 检查该消息之后是否已有退出通知
        let hasExitNotice = messages[lastEntryIndex...].contains(where: { msg in
            // injectDirectModeSummary / 恢复逻辑 注入的隐藏 AI 上下文
            (msg.role == .system && msg.systemMessageType == .aiContext
                && (msg.content.hasPrefix("[Context] Direct session")
                    || msg.content.contains("Previous direct agent session was interrupted")))
            // exitDirectMode 注入的系统消息（匹配所有语言）
            || (msg.role == .system && msg.systemMessageType == .info
                && msg.content.contains("ConchTalk AI"))
        })

        guard !hasExitNotice else { return }

        // 补注恢复消息
        await appendAIContextMessage(
            "[Context] Previous direct agent session was interrupted (app terminated). Returned to ConchTalk AI mode. Continue helping the user normally."
        )
    }

    // MARK: - 状态清理辅助

    /// 清理加载中的占位消息。
    func removeLoadingMessages() {
        messages.removeAll { $0.isLoading }
    }

    /// 清理审批弹窗状态。
    func clearPendingInteractionState() {
        showConfirmation = false
        pendingToolCall = nil
    }

    /// 清理流式阶段的瞬时 UI 状态。
    func clearTransientStreamingState() {
        isStreaming = false
        isReasoningActive = false
        activeReasoningText = ""
        activeContentText = ""
        liveToolOutput = nil
        agentStreamEvents = []
        isAgentExecuting = false
        directStreamScrollTask?.cancel()
        directStreamScrollTask = nil
    }

    /// 直连模式执行中插入占位 assistant 消息，让流式事件有渲染载体。
    func ensureDirectModeLoadingMessage() {
        guard !messages.contains(where: { $0.isLoading }) else { return }
        let source = directModePresentation.agentName.map { MessageSource.directAgent(agentName: $0) }
        messages.append(Message(role: .assistant, content: "", isLoading: true, source: source))
    }

    /// 节流 direct mode 的滚动触发，避免每个 token 都驱动一次 ScrollView 更新。
    func scheduleDirectStreamScroll() {
        guard directStreamScrollTask == nil else { return }
        directStreamScrollTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            guard let self, !Task.isCancelled else { return }
            self.streamingScrollTrigger &+= 1
            self.directStreamScrollTask = nil
        }
    }

    /// 从 SwiftData 重新加载当前服务器消息。
    func reloadMessagesFromStore() async {
        do {
            let loaded = try await store.fetchMessages(forServer: serverID)
            if !loaded.isEmpty {
                messages = loaded
            }
        } catch {
            print("[ChatVM] Failed to reload messages: \(error)")
        }
    }

    // MARK: - 协调器初始化与回调绑定

    static func makeAgentPickerCoordinator(
        sshManager: SSHSessionManager,
        server: Server,
        taskCoordinator: TaskExecutionCoordinator
    ) -> AgentPickerCoordinator {
        AgentPickerCoordinator(
            sshManager: sshManager,
            server: server,
            taskCoordinator: taskCoordinator
        )
    }

    func bindCoordinators() {
        agentPicker.bind(
            onSystemMessage: { [weak self] text, type in
                self?.appendSystemMessage(text, type: type)
            },
            onConfirmConnection: { [weak self] agent, cwd in
                guard let self else { return }
                Task {
                    await self.directSessionCoordinator.connect(
                        agent: agent,
                        cwd: cwd,
                        sshClient: await self.resolveSSHClient(),
                        currentMessageCount: self.messages.count
                    )
                }
            }
        )
    }

    // MARK: - SSH 客户端解析

    /// 从 SSHSessionManager 获取当前服务器的 Citadel SSHClient。
    private func resolveSSHClient() async -> SSHClient? {
        guard let nioClient = sshManager.getClient(for: serverID) else { return nil }
        return await nioClient.citadelClient
    }

    // MARK: - 直连 session 事件消费

    /// 启动事件流消费任务。
    func startDirectSessionEventConsumption() {
        directEventTask = Task { [weak self] in
            guard let self else { return }
            for await event in self.directSessionCoordinator.events {
                guard !Task.isCancelled else { break }
                await self.handleDirectSessionEvent(event)
            }
        }
    }

    /// 处理 DirectSessionCoordinator 发出的事件。
    func handleDirectSessionEvent(_ event: DirectSessionEvent) async {
        switch event {
        case .messageReady(let msg):
            if msg.role == .assistant {
                removeLoadingMessages()
            }
            messages.append(msg)
            try? await store.addMessage(msg, toServer: serverID)
            streamingScrollTrigger &+= 1
        case .lifecycleChanged(let lifecycle):
            switch lifecycle {
            case .executing:
                isAgentExecuting = true
                isStreaming = true
                ensureDirectModeLoadingMessage()
            case .connected:
                isAgentExecuting = false
                isStreaming = false
                directStreamScrollTask?.cancel()
                directStreamScrollTask = nil
                removeLoadingMessages()
            case .idle:
                isAgentExecuting = false
                isStreaming = false
                isProcessing = false
                directStreamScrollTask?.cancel()
                directStreamScrollTask = nil
                removeLoadingMessages()
                agentStreamEvents = []
            default:
                break
            }
        case .streamUpdate(let agentEvent):
            if case .text(let text) = agentEvent,
               case .text(let previous)? = agentStreamEvents.last {
                agentStreamEvents[agentStreamEvents.count - 1] = .text(previous + text)
            } else if case .thinking(let text) = agentEvent,
                      case .thinking(let previous)? = agentStreamEvents.last {
                agentStreamEvents[agentStreamEvents.count - 1] = .thinking(previous + text)
            } else {
                agentStreamEvents.append(agentEvent)
            }
            scheduleDirectStreamScroll()
        case .contextSummaryReady(let summary):
            let aiMsg = Message(role: .system, content: summary, systemMessageType: .aiContext)
            messages.append(aiMsg)
            try? await store.addMessage(aiMsg, toServer: serverID)
        case .metadataUpdated:
            break // state 已通过 directSessionCoordinator.state 可观察
        case .error(let errorText):
            appendSystemMessage(errorText, type: .error)
        }
    }

    // MARK: - 排队消息管理

    /// 将消息标记为排队等待状态。
    func markAsQueued(_ messageID: UUID) {
        queuedMessageIDs.insert(messageID)
    }

    /// 将消息从排队状态移除（开始执行时调用）。
    func markAsExecuting(_ messageID: UUID) {
        queuedMessageIDs.remove(messageID)
    }

    /// 撤回排队中的消息（仅可撤回尚未开始执行的消息）。
    func recallQueuedMessage(_ messageID: UUID) {
        guard queuedMessageIDs.contains(messageID) else { return }
        taskCoordinator.cancelQueuedTask(serverID: serverID, taskID: messageID)
        queuedMessageIDs.remove(messageID)
        messages.removeAll { $0.id == messageID }
    }
}
