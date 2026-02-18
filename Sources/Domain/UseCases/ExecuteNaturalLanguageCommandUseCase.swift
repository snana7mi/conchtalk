import Foundation

final class ExecuteNaturalLanguageCommandUseCase: @unchecked Sendable {
    private let aiService: AIServiceProtocol
    private let sshClient: SSHClientProtocol
    private let safetyValidator: CommandSafetyValidating

    enum CommandApproval: Sendable {
        case approved
        case denied
    }

    // Callback for when a command needs user confirmation
    var onCommandNeedsConfirmation: (@Sendable (SSHCommand) async -> CommandApproval)?
    // Callback for streaming intermediate messages to UI
    var onIntermediateMessage: (@MainActor @Sendable (Message) -> Void)?

    init(aiService: AIServiceProtocol, sshClient: SSHClientProtocol, safetyValidator: CommandSafetyValidating) {
        self.aiService = aiService
        self.sshClient = sshClient
        self.safetyValidator = safetyValidator
    }

    func execute(userMessage: String, conversationHistory: [Message], serverContext: String) async throws -> [Message] {
        var newMessages: [Message] = []
        var history = conversationHistory

        // Send user message to AI
        var response = try await aiService.sendMessage(userMessage, conversationHistory: history, serverContext: serverContext)

        // Agentic loop
        let maxIterations = 10
        var iteration = 0
        while iteration < maxIterations {
            iteration += 1

            switch response {
            case .text(let text):
                let assistantMsg = Message(role: .assistant, content: text)
                newMessages.append(assistantMsg)
                onIntermediateMessage?(assistantMsg)
                return newMessages // Done!

            case .command(let sshCommand):
                let safetyLevel = safetyValidator.validate(sshCommand)

                switch safetyLevel {
                case .safe:
                    // Auto-execute
                    let output = try await sshClient.execute(command: sshCommand.command)
                    let cmdMsg = Message(role: .command, content: sshCommand.explanation, command: sshCommand, commandOutput: output)
                    newMessages.append(cmdMsg)
                    history.append(cmdMsg)
                    onIntermediateMessage?(cmdMsg)

                    response = try await aiService.sendCommandResult(output, forCommand: sshCommand, conversationHistory: history, serverContext: serverContext)

                case .needsConfirmation:
                    // Ask user
                    let approval = await onCommandNeedsConfirmation?(sshCommand) ?? .denied

                    if approval == .approved {
                        let output = try await sshClient.execute(command: sshCommand.command)
                        let cmdMsg = Message(role: .command, content: sshCommand.explanation, command: sshCommand, commandOutput: output)
                        newMessages.append(cmdMsg)
                        history.append(cmdMsg)
                        onIntermediateMessage?(cmdMsg)

                        response = try await aiService.sendCommandResult(output, forCommand: sshCommand, conversationHistory: history, serverContext: serverContext)
                    } else {
                        let deniedMsg = Message(role: .system, content: "Command denied by user: \(sshCommand.command)")
                        newMessages.append(deniedMsg)
                        history.append(deniedMsg)

                        response = try await aiService.sendCommandResult("DENIED: User rejected this command", forCommand: sshCommand, conversationHistory: history, serverContext: serverContext)
                    }

                case .forbidden:
                    let blockedMsg = Message(role: .system, content: "Blocked dangerous command: \(sshCommand.command)")
                    newMessages.append(blockedMsg)
                    history.append(blockedMsg)
                    onIntermediateMessage?(blockedMsg)

                    response = try await aiService.sendCommandResult("BLOCKED: This command is forbidden for safety reasons", forCommand: sshCommand, conversationHistory: history, serverContext: serverContext)
                }
            }
        }

        let timeoutMsg = Message(role: .system, content: "Reached maximum command execution limit")
        newMessages.append(timeoutMsg)
        return newMessages
    }
}
