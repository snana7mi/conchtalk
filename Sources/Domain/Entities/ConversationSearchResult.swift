import Foundation

struct ConversationSearchResult: Identifiable, Sendable {
    let id: UUID
    let conversationTitle: String
    let serverName: String
    let serverID: UUID
    let matchingSnippet: String
    let updatedAt: Date
}
