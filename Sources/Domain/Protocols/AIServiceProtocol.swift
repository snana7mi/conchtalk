import Foundation

// The AI backend response type
enum AIResponse: Sendable {
    case text(String, reasoning: String?)              // Final text answer from AI, optionally with reasoning chain
    case toolCall(ToolCall, reasoning: String?)         // AI wants to invoke a tool, optionally with reasoning chain
}

protocol AIServiceProtocol: Sendable {
    func sendMessage(_ message: String, conversationHistory: [Message], serverContext: String) async throws -> AIResponse
    func sendToolResult(_ result: String, forToolCall: ToolCall, conversationHistory: [Message], serverContext: String) async throws -> AIResponse
    func sendMessageStreaming(_ message: String, conversationHistory: [Message], serverContext: String) -> AsyncStream<StreamingDelta>
    func sendToolResultStreaming(_ result: String, forToolCall: ToolCall, conversationHistory: [Message], serverContext: String) -> AsyncStream<StreamingDelta>
    func estimateContextUsage(history: [Message], serverContext: String) -> Double
}
