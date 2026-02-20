/// 文件说明：ChatViewModel，负责聊天页面状态管理、SSH 会话联动与 AI 对话编排。
import SwiftUI
import SwiftData

/// ChatViewModel：
/// 作为 Chat 页面状态中枢，负责管理消息与输入状态、协调 SSH 连接，
/// 并驱动 AI/工具调用流程将中间结果实时回写到界面。
@Observable
final class ChatViewModel {
    var messages: [Message] = []
    var inputText: String = ""
    var isProcessing: Bool = false
    var isConnected: Bool = false
    var error: String?
    var pendingToolCall: ToolCall?
    var showConfirmation: Bool = false
    var contextUsagePercent: Double = 0
    var activeReasoningText: String = ""
    var activeContentText: String = ""
    var isStreaming: Bool = false
    var isReasoningActive: Bool = false
    var thinkingBubbleId: UUID = UUID()
    /// 工具执行过程中的实时输出文本，供 UI 在加载气泡中展示命令执行进度。
    /// - Note: 当前为缓冲模式（工具执行完成后一次性推送）；未来接入流式执行后将逐块更新。
    var liveToolOutput: String = ""
    /// 当前会话标题，用于导航栏显示。
    var conversationTitle: String = ""

    private var server: Server
    private var conversationID: UUID
    private let store: SwiftDataStore
    private let sshManager: SSHSessionManager
    private let aiService: AIServiceProtocol
    private let toolRegistry: ToolRegistryProtocol
    private let keychainService: KeychainServiceProtocol

    private var commandContinuation: CheckedContinuation<ExecuteNaturalLanguageCommandUseCase.CommandApproval, Never>?
    /// 标记会话标题是否已自动生成，避免每次发送消息重复生成。
    private var titleGenerated: Bool = false

    /// 初始化聊天视图模型并注入业务依赖。
    /// - Parameters:
    ///   - server: 当前会话绑定的远端服务器。
    ///   - conversationID: 会话 ID；为空时会自动创建新的会话标识。
    ///   - store: 本地会话与消息持久化存储。
    ///   - sshManager: SSH 连接管理器。
    ///   - aiService: AI 服务抽象。
    ///   - toolRegistry: 工具注册表。
    ///   - keychainService: 密码/密钥读取服务。
    init(server: Server, conversationID: UUID? = nil, store: SwiftDataStore, sshManager: SSHSessionManager, aiService: AIServiceProtocol, toolRegistry: ToolRegistryProtocol, keychainService: KeychainServiceProtocol) {
        self.server = server
        self.conversationID = conversationID ?? UUID()
        self.store = store
        self.sshManager = sshManager
        self.aiService = aiService
        self.toolRegistry = toolRegistry
        self.keychainService = keychainService
    }

    var serverDisplayName: String {
        if conversationTitle.isEmpty {
            return server.name
        }
        return "\(server.name) - \(conversationTitle)"
    }

    /// 基于当前消息历史估算上下文窗口占用比例。
    /// - Note: 会忽略 `isLoading` 的占位消息，仅统计真实对话内容。
    func updateContextUsage() {
        let detectedOS = sshManager.getDetectedOS(for: server.id)
        let serverContext = "Host: \(server.host), User: \(server.username), OS: \(detectedOS)"
        contextUsagePercent = aiService.estimateContextUsage(
            history: messages.filter { !$0.isLoading },
            serverContext: serverContext
        )
    }

    /// 加载当前会话消息；若会话不存在则创建新会话并写入初始系统消息。
    /// - Important: 失败时会写入 `error` 供 UI 展示。
    func loadMessages() async {
        do {
            let conversations = try await store.fetchConversations(forServer: server.id)
            if let existing = conversations.first(where: { $0.id == conversationID }) {
                messages = existing.messages
                // 已有非默认标题的会话无需再次生成标题。
                if existing.title != "New Conversation" {
                    titleGenerated = true
                    conversationTitle = existing.title
                }
                updateContextUsage()
            } else {
                // Create new conversation
                let conversation = Conversation(id: conversationID, serverID: server.id)
                try await store.saveConversation(conversation)
                let systemMsg = Message(role: .system, content: String(localized: "Connected to \(server.name) (\(server.host))"))
                messages = [systemMsg]
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// 建立到当前服务器的 SSH 连接，并把结果写入会话消息流。
    /// - Important: 成功后设置 `isConnected = true`；失败会追加系统错误消息。
    func connect() async {
        do {
            var password: String? = nil
            if case .password = server.authMethod {
                password = try keychainService.getPassword(forServer: server.id)
            }
            try await sshManager.connect(to: server, password: password, keychainService: keychainService)
            isConnected = true

            let connectMsg = Message(role: .system, content: String(localized: "SSH connection established"))
            messages.append(connectMsg)
            try await store.addMessage(connectMsg, toConversation: conversationID)
        } catch {
            isConnected = false
            self.error = String(localized: "Connection failed: \(error.localizedDescription)")
            let errorMsg = Message(role: .system, content: String(localized: "Connection failed: \(error.localizedDescription)"))
            messages.append(errorMsg)
        }
    }

    /// 检查底层 SSH 连接是否仍然存活（不触发重连和 UI 消息）。
    /// - Returns: `true` 表示底层连接仍可用；`false` 表示已断开。
    func checkConnectionAlive() async -> Bool {
        let alive = await sshManager.isConnected
        if !alive {
            isConnected = false
        }
        return alive
    }

    /// 主动断开 SSH 连接并更新本地连接状态。
    func disconnect() async {
        await sshManager.disconnect(from: server.id)
        isConnected = false
        let msg = Message(role: .system, content: String(localized: "Disconnected"))
        messages.append(msg)
    }

    /// 发送输入框内容并执行一轮完整的 AI Agent 流程（含工具调用与审批）。
    /// - Important: 会修改 `messages`、`isProcessing`、`isStreaming`、`activeReasoningText` 等 UI 状态。
    /// - Note: 过程中会把新增消息写入 `store`，结束后刷新上下文占用比例。
    func sendMessage() async {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isProcessing else { return }

        inputText = ""
        isProcessing = true
        error = nil

        // Add user message
        let userMsg = Message(role: .user, content: text)
        messages.append(userMsg)
        try? await store.addMessage(userMsg, toConversation: conversationID)

        // Add loading indicator
        let loadingMsg = Message(id: UUID(), role: .assistant, content: "", isLoading: true)
        messages.append(loadingMsg)

        do {
            guard let sshClient = sshManager.getClient(for: server.id) else {
                throw SSHError.notConnected
            }

            let useCase = ExecuteNaturalLanguageCommandUseCase(
                aiService: aiService,
                sshClient: sshClient,
                toolRegistry: toolRegistry
            )

            let detectedOS = sshManager.getDetectedOS(for: server.id)
            let serverContext = "Host: \(server.host), User: \(server.username), OS: \(detectedOS)"

            // Reset streaming state
            activeReasoningText = ""
            activeContentText = ""
            isStreaming = true
            isReasoningActive = false
            thinkingBubbleId = UUID()

            useCase.onToolCallNeedsConfirmation = { [weak self] toolCall in
                guard let self else { return .denied }
                return await self.requestConfirmation(for: toolCall)
            }

            useCase.onReasoningUpdate = { [weak self] chunk in
                guard let self else { return }
                self.activeReasoningText += chunk
                self.isReasoningActive = true
            }

            useCase.onContentUpdate = { [weak self] chunk in
                guard let self else { return }
                self.activeContentText += chunk
                self.isReasoningActive = false
            }

            useCase.onToolOutputUpdate = { [weak self] output in
                guard let self else { return }
                self.liveToolOutput = output
            }

            useCase.onIntermediateMessage = { [weak self] message in
                guard let self else { return }
                // Remove loading indicator and add the real message
                self.messages.removeAll { $0.isLoading }
                self.messages.append(message)
                // Reset streaming state for next round — each round gets its own thinking bubble
                self.activeContentText = ""
                self.activeReasoningText = ""
                self.isReasoningActive = false
                // 工具执行完成，清除实时输出
                self.liveToolOutput = ""
                // Add new loading indicator if more processing expected
                if message.role == .command {
                    self.isStreaming = true
                    self.thinkingBubbleId = UUID()
                    let loading = Message(id: UUID(), role: .assistant, content: "", isLoading: true)
                    self.messages.append(loading)
                }
            }

            let resultMessages = try await useCase.execute(
                userMessage: text,
                conversationHistory: messages.filter { !$0.isLoading },
                serverContext: serverContext
            )

            // Remove loading indicator
            messages.removeAll { $0.isLoading }

            // Persist new messages
            for msg in resultMessages {
                if !messages.contains(where: { $0.id == msg.id }) {
                    messages.append(msg)
                }
                try? await store.addMessage(msg, toConversation: conversationID)
            }

            // 首次 AI 回复后自动生成会话标题
            await generateConversationTitle()

        } catch {
            print("[ChatVM] Error: \(error)")
            messages.removeAll { $0.isLoading }
            let errorMsg = Message(role: .system, content: String(localized: "Error: \(error.localizedDescription)"))
            messages.append(errorMsg)
            self.error = error.localizedDescription
        }

        isStreaming = false
        isReasoningActive = false
        activeReasoningText = ""
        activeContentText = ""
        liveToolOutput = ""
        isProcessing = false
        updateContextUsage()
    }

    // MARK: - 会话标题自动生成

    /// 调用 AI 根据对话内容自动生成简短的会话标题，仅在标题仍为默认值时触发一次。
    /// - Note: AI 生成失败时降级为截取首条用户消息。fallback 持久化成功后才锁定状态，确保失败可重试。
    private func generateConversationTitle() async {
        guard !titleGenerated else { return }
        guard let firstUserMsg = messages.first(where: { $0.role == .user }) else { return }

        let firstContent = firstUserMsg.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !firstContent.isEmpty else { return }

        // 先用截取策略作为即时标题
        let fallbackTitle = firstContent.count > 20
            ? String(firstContent.prefix(20)) + "..."
            : firstContent

        // 只有 fallback 持久化成功后才锁定，避免写入失败时永不重试
        do {
            try await store.updateConversationTitle(conversationID, title: fallbackTitle)
            titleGenerated = true
            conversationTitle = fallbackTitle
        } catch {
            print("[ChatVM] Failed to persist fallback title, will retry next message: \(error)")
            return
        }

        // 异步调用 AI 生成更精准的标题（失败不影响已有 fallback）
        Task { [weak self, aiService, store, conversationID, messages] in
            do {
                let aiTitle = try await aiService.generateTitle(for: messages)
                guard !aiTitle.isEmpty else { return }
                let finalTitle = aiTitle.count > 30
                    ? String(aiTitle.prefix(30)) + "..."
                    : aiTitle
                try await store.updateConversationTitle(conversationID, title: finalTitle)
                self?.conversationTitle = finalTitle
                print("[ChatVM] AI generated title: \(finalTitle)")
            } catch {
                print("[ChatVM] AI title generation failed, keeping fallback: \(error)")
            }
        }
    }

    /// 发起工具调用审批，并通过 continuation 挂起等待用户操作。
    /// - Parameter toolCall: 待审批的工具调用。
    /// - Returns: 用户审批结果（同意/拒绝）。
    private func requestConfirmation(for toolCall: ToolCall) async -> ExecuteNaturalLanguageCommandUseCase.CommandApproval {
        pendingToolCall = toolCall
        showConfirmation = true

        return await withCheckedContinuation { continuation in
            self.commandContinuation = continuation
        }
    }

    /// 同意当前待审批工具调用并恢复执行流程。
    func approveCommand() {
        showConfirmation = false
        pendingToolCall = nil
        commandContinuation?.resume(returning: .approved)
        commandContinuation = nil
    }

    /// 拒绝当前待审批工具调用并恢复执行流程。
    func denyCommand() {
        showConfirmation = false
        pendingToolCall = nil
        commandContinuation?.resume(returning: .denied)
        commandContinuation = nil
    }
}

// MARK: - SwiftDataStore 会话标题更新扩展

extension SwiftDataStore {
    /// 更新指定会话的标题。
    /// - Parameters:
    ///   - conversationID: 目标会话标识。
    ///   - title: 新标题。
    /// - Throws: SwiftData 查询/保存失败时抛出。
    /// - Note: 若会话不存在则静默返回。
    func updateConversationTitle(_ conversationID: UUID, title: String) throws {
        let predicate = #Predicate<ConversationModel> { $0.id == conversationID }
        let descriptor = FetchDescriptor(predicate: predicate)
        if let conversation = try modelContext.fetch(descriptor).first {
            conversation.title = title
            conversation.updatedAt = Date()
            try modelContext.save()
        }
    }
}
