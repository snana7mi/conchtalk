import Foundation

/// A tool call from the AI, stored in Message and persisted via MessageModel.
nonisolated struct ToolCall: Codable, Sendable {
    let id: String              // OpenAI tool_call ID (e.g. "call_abc123")
    let toolName: String        // "execute_ssh_command", "read_file", etc.
    let argumentsJSON: Data     // Raw JSON arguments, each tool decodes its own
    let explanation: String     // Human-readable explanation from AI

    /// Decode arguments into a dictionary for tool dispatch.
    func decodedArguments() throws -> [String: Any] {
        guard let dict = try JSONSerialization.jsonObject(with: argumentsJSON) as? [String: Any] else {
            throw ToolError.invalidArguments("Failed to decode arguments as JSON object")
        }
        return dict
    }
}
