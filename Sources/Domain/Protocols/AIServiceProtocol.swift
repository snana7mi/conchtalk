import Foundation

// The AI backend response type
enum AIResponse: Sendable {
    case text(String)                    // Final text answer from AI
    case command(SSHCommand)             // AI wants to execute a command
}

protocol AIServiceProtocol: Sendable {
    func sendMessage(_ message: String, conversationHistory: [Message], serverContext: String) async throws -> AIResponse
    func sendCommandResult(_ result: String, forCommand: SSHCommand, conversationHistory: [Message], serverContext: String) async throws -> AIResponse
}
