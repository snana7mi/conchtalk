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

    private var server: Server
    private var conversationID: UUID
    private let store: SwiftDataStore
    private let sshManager: SSHSessionManager
    private let aiService: AIServiceProtocol
    private let toolRegistry: ToolRegistryProtocol
    private let keychainService: KeychainServiceProtocol

    private var commandContinuation: CheckedContinuation<ExecuteNaturalLanguageCommandUseCase.CommandApproval, Never>?

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
        "\(server.username)@\(server.host)"
    }

    /// 基于当前消息历史估算上下文窗口占用比例。
    /// - Note: 会忽略 `isLoading` 的占位消息，仅统计真实对话内容。
    func updateContextUsage() {
        let serverContext = "Host: \(server.host), User: \(server.username), OS: Linux"
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

            let serverContext = "Host: \(server.host), User: \(server.username), OS: Linux"

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

            useCase.onIntermediateMessage = { [weak self] message in
                guard let self else { return }
                // Remove loading indicator and add the real message
                self.messages.removeAll { $0.isLoading }
                self.messages.append(message)
                // Reset streaming state for next round — each round gets its own thinking bubble
                self.activeContentText = ""
                self.activeReasoningText = ""
                self.isReasoningActive = false
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
        isProcessing = false
        updateContextUsage()
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
