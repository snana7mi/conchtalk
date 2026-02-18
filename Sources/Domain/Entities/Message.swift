import Foundation

nonisolated struct Message: Identifiable, Sendable {
    let id: UUID
    var role: MessageRole
    var content: String
    var timestamp: Date
    var toolCall: ToolCall?     // Non-nil for tool-call messages
    var toolOutput: String?     // Raw output from tool execution
    var isLoading: Bool

    enum MessageRole: String, Codable, Sendable {
        case user
        case assistant
        case command       // Kept as "command" for backward compat with persisted roleRaw
        case system
    }

    init(id: UUID = UUID(), role: MessageRole, content: String, timestamp: Date = Date(), toolCall: ToolCall? = nil, toolOutput: String? = nil, isLoading: Bool = false) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.toolCall = toolCall
        self.toolOutput = toolOutput
        self.isLoading = isLoading
    }
}
