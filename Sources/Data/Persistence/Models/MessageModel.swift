import Foundation
import SwiftData

@Model
final class MessageModel {
    @Attribute(.unique) var id: UUID
    var roleRaw: String
    var content: String
    var timestamp: Date
    var commandJSON: Data?     // Legacy: encoded SSHCommand (read-only for backward compat)
    var commandOutput: String? // Legacy field name, also used by new messages
    var toolCallJSON: Data?    // New: encoded ToolCall

    var conversation: ConversationModel?

    init(id: UUID = UUID(), roleRaw: String, content: String, timestamp: Date = Date(), commandJSON: Data? = nil, commandOutput: String? = nil, toolCallJSON: Data? = nil) {
        self.id = id
        self.roleRaw = roleRaw
        self.content = content
        self.timestamp = timestamp
        self.commandJSON = commandJSON
        self.commandOutput = commandOutput
        self.toolCallJSON = toolCallJSON
    }

    func toDomain() -> Message {
        let role = Message.MessageRole(rawValue: roleRaw) ?? .system

        // Try new toolCallJSON first
        if let data = toolCallJSON, let toolCall = try? JSONDecoder().decode(ToolCall.self, from: data) {
            return Message(id: id, role: role, content: content, timestamp: timestamp, toolCall: toolCall, toolOutput: commandOutput, isLoading: false)
        }

        // Fallback: legacy SSHCommand → wrap as ToolCall
        if let data = commandJSON, let sshCommand = try? JSONDecoder().decode(SSHCommand.self, from: data) {
            let argsJSON = data // SSHCommand JSON is already the arguments
            let toolCall = ToolCall(
                id: "legacy_\(id.uuidString.prefix(8))",
                toolName: "execute_ssh_command",
                argumentsJSON: argsJSON,
                explanation: sshCommand.explanation
            )
            return Message(id: id, role: role, content: content, timestamp: timestamp, toolCall: toolCall, toolOutput: commandOutput, isLoading: false)
        }

        return Message(id: id, role: role, content: content, timestamp: timestamp, toolCall: nil, toolOutput: nil, isLoading: false)
    }

    static func fromDomain(_ message: Message) -> MessageModel {
        var toolCallData: Data? = nil
        if let tc = message.toolCall {
            toolCallData = try? JSONEncoder().encode(tc)
        }
        return MessageModel(
            id: message.id,
            roleRaw: message.role.rawValue,
            content: message.content,
            timestamp: message.timestamp,
            commandJSON: nil,  // No longer write legacy field
            commandOutput: message.toolOutput,
            toolCallJSON: toolCallData
        )
    }
}
