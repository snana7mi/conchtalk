import Foundation
import SwiftData

@Model
final class ConversationModel {
    @Attribute(.unique) var id: UUID
    var serverID: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date

    @Relationship(deleteRule: .cascade)
    var messages: [MessageModel] = []

    var server: ServerModel?

    init(id: UUID = UUID(), serverID: UUID, title: String = "New Conversation", createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.serverID = serverID
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    func toDomain() -> Conversation {
        let domainMessages = messages
            .sorted { $0.timestamp < $1.timestamp }
            .map { $0.toDomain() }
        return Conversation(id: id, serverID: serverID, title: title, messages: domainMessages, createdAt: createdAt, updatedAt: updatedAt)
    }
}
