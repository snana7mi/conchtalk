import Foundation

nonisolated struct Message: Identifiable, Sendable {
    let id: UUID
    var role: MessageRole
    var content: String
    var timestamp: Date
    var command: SSHCommand?    // Non-nil for command-type messages
    var commandOutput: String?  // Raw output from SSH execution
    var isLoading: Bool

    enum MessageRole: String, Codable, Sendable {
        case user
        case assistant
        case command
        case system
    }

    init(id: UUID = UUID(), role: MessageRole, content: String, timestamp: Date = Date(), command: SSHCommand? = nil, commandOutput: String? = nil, isLoading: Bool = false) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.command = command
        self.commandOutput = commandOutput
        self.isLoading = isLoading
    }
}
