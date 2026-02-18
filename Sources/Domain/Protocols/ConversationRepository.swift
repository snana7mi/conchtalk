import Foundation

protocol ConversationRepository: Sendable {
    func save(_ conversation: Conversation) async throws
    func fetch(forServer serverID: UUID) async throws -> [Conversation]
    func fetchAll() async throws -> [Conversation]
    func delete(_ conversationID: UUID) async throws
    func addMessage(_ message: Message, to conversationID: UUID) async throws
}
