import Foundation
import SwiftData

@Model
final class MessageModel {
    @Attribute(.unique) var id: UUID
    var roleRaw: String
    var content: String
    var timestamp: Date
    var commandJSON: Data?     // Encoded SSHCommand
    var commandOutput: String?

    var conversation: ConversationModel?

    init(id: UUID = UUID(), roleRaw: String, content: String, timestamp: Date = Date(), commandJSON: Data? = nil, commandOutput: String? = nil) {
        self.id = id
        self.roleRaw = roleRaw
        self.content = content
        self.timestamp = timestamp
        self.commandJSON = commandJSON
        self.commandOutput = commandOutput
    }

    func toDomain() -> Message {
        let role = Message.MessageRole(rawValue: roleRaw) ?? .system
        var command: SSHCommand? = nil
        if let data = commandJSON {
            command = try? JSONDecoder().decode(SSHCommand.self, from: data)
        }
        return Message(id: id, role: role, content: content, timestamp: timestamp, command: command, commandOutput: commandOutput, isLoading: false)
    }

    static func fromDomain(_ message: Message) -> MessageModel {
        var commandData: Data? = nil
        if let cmd = message.command {
            commandData = try? JSONEncoder().encode(cmd)
        }
        return MessageModel(id: message.id, roleRaw: message.role.rawValue, content: message.content, timestamp: message.timestamp, commandJSON: commandData, commandOutput: message.commandOutput)
    }
}
