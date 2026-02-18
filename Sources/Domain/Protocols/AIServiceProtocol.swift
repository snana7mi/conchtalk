import Foundation

// The AI backend response type
enum AIResponse: Sendable {
    case text(String)                    // Final text answer from AI
    case toolCall(ToolCall)              // AI wants to invoke a tool
}

protocol AIServiceProtocol: Sendable {
    func sendMessage(_ message: String, conversationHistory: [Message], serverContext: String) async throws -> AIResponse
    func sendToolResult(_ result: String, forToolCall: ToolCall, conversationHistory: [Message], serverContext: String) async throws -> AIResponse
}
