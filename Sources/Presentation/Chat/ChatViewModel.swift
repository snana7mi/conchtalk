import SwiftUI
import SwiftData

@Observable
final class ChatViewModel {
    var messages: [Message] = []
    var inputText: String = ""
    var isProcessing: Bool = false
    var isConnected: Bool = false
    var error: String?
    var pendingToolCall: ToolCall?
    var showConfirmation: Bool = false

    private var server: Server
    private var conversationID: UUID
    private let store: SwiftDataStore
    private let sshManager: SSHSessionManager
    private let aiService: AIServiceProtocol
    private let toolRegistry: ToolRegistryProtocol
    private let keychainService: KeychainServiceProtocol

    private var commandContinuation: CheckedContinuation<ExecuteNaturalLanguageCommandUseCase.CommandApproval, Never>?

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

    func loadMessages() async {
        do {
            let conversations = try await store.fetchConversations(forServer: server.id)
            if let existing = conversations.first(where: { $0.id == conversationID }) {
                messages = existing.messages
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

    func disconnect() async {
        await sshManager.disconnect(from: server.id)
        isConnected = false
        let msg = Message(role: .system, content: String(localized: "Disconnected"))
        messages.append(msg)
    }

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

            useCase.onToolCallNeedsConfirmation = { [weak self] toolCall in
                guard let self else { return .denied }
                return await self.requestConfirmation(for: toolCall)
            }

            useCase.onIntermediateMessage = { [weak self] message in
                guard let self else { return }
                // Remove loading indicator and add the real message
                self.messages.removeAll { $0.isLoading }
                self.messages.append(message)
                // Add new loading indicator if more processing expected
                if message.role == .command {
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
            messages.removeAll { $0.isLoading }
            let errorMsg = Message(role: .system, content: String(localized: "Error: \(error.localizedDescription)"))
            messages.append(errorMsg)
            self.error = error.localizedDescription
        }

        isProcessing = false
    }

    private func requestConfirmation(for toolCall: ToolCall) async -> ExecuteNaturalLanguageCommandUseCase.CommandApproval {
        pendingToolCall = toolCall
        showConfirmation = true

        return await withCheckedContinuation { continuation in
            self.commandContinuation = continuation
        }
    }

    func approveCommand() {
        showConfirmation = false
        pendingToolCall = nil
        commandContinuation?.resume(returning: .approved)
        commandContinuation = nil
    }

    func denyCommand() {
        showConfirmation = false
        pendingToolCall = nil
        commandContinuation?.resume(returning: .denied)
        commandContinuation = nil
    }
}
