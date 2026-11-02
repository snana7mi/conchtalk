/// 文件说明：LiveServerBatchExecutor，在每台服务器上连接 SSH 并跑同一条提示词。
import Foundation

/// LiveServerBatchExecutor：
/// 每台服务器单独 `ensureConnected`，再调用 `TaskExecutionCoordinator.runPrompt`。
/// 审批进入该服务器自己的确认槽，一台的批准不会应用到另一台。
@MainActor
final class LiveServerBatchExecutor: ServerBatchExecuting {
    private let sshManager: SSHSessionManager
    private let keychain: any KeychainServiceProtocol
    private let coordinator: TaskExecutionCoordinator
    private let messages: ChatMessageRepository
    /// 聊天页已打开时，把用户消息插进当前列表。
    var onUserMessage: ((Server, Message) -> Void)?

    init(
        sshManager: SSHSessionManager,
        keychain: any KeychainServiceProtocol,
        coordinator: TaskExecutionCoordinator,
        messages: ChatMessageRepository,
        onUserMessage: ((Server, Message) -> Void)? = nil
    ) {
        self.sshManager = sshManager
        self.keychain = keychain
        self.coordinator = coordinator
        self.messages = messages
        self.onUserMessage = onUserMessage
    }

    nonisolated func run(server: Server, prompt: String) async -> ServerBatchServerResult {
        await runOnMain(server: server, prompt: prompt)
    }

    private func runOnMain(server: Server, prompt: String) async -> ServerBatchServerResult {
        do {
            var password: String?
            if case .password = server.authMethod {
                password = try keychain.getPassword(forServer: server.id)
            }
            try await sshManager.ensureConnected(
                to: server,
                password: password,
                keychainService: keychain
            )
        } catch {
            return ServerBatchServerResult(
                serverID: server.id,
                serverName: server.name,
                succeeded: false,
                summary: error.localizedDescription
            )
        }

        let history = (try? await messages.reloadMessages(forServer: server.id)) ?? []
        let outcome = await coordinator.runPrompt(server: server, prompt: prompt, history: history) { message in
            self.onUserMessage?(server, message)
        }
        let summary: String
        if outcome.succeeded {
            summary = ServerBatchReportBuilder.clippedSummary(outcome.assistantText)
        } else {
            summary = outcome.errorSummary ?? "Failed"
        }
        return ServerBatchServerResult(
            serverID: server.id,
            serverName: server.name,
            succeeded: outcome.succeeded,
            summary: summary
        )
    }
}
