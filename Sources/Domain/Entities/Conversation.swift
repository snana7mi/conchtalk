import Foundation

struct Conversation: Identifiable, Hashable, Sendable {
    let id: UUID
    var serverID: UUID
    var title: String
    var messages: [Message]
    var createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(), serverID: UUID, title: String = "New Conversation", messages: [Message] = [], createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.serverID = serverID
        self.title = title
        self.messages = messages
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: Conversation, rhs: Conversation) -> Bool {
        lhs.id == rhs.id
    }
}
