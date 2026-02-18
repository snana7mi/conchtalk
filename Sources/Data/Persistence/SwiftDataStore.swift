import Foundation
import SwiftData

@ModelActor
actor SwiftDataStore {

    // MARK: - Server Operations

    func saveServer(_ server: Server) throws {
        let model = ServerModel.fromDomain(server)
        modelContext.insert(model)
        try modelContext.save()
    }

    func fetchServers() throws -> [Server] {
        let descriptor = FetchDescriptor<ServerModel>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        let models = try modelContext.fetch(descriptor)
        return models.map { $0.toDomain() }
    }

    func deleteServer(_ serverID: UUID) throws {
        let predicate = #Predicate<ServerModel> { $0.id == serverID }
        let descriptor = FetchDescriptor(predicate: predicate)
        if let model = try modelContext.fetch(descriptor).first {
            modelContext.delete(model)
            try modelContext.save()
        }
    }

    func updateServer(_ server: Server) throws {
        let predicate = #Predicate<ServerModel> { $0.id == server.id }
        let descriptor = FetchDescriptor(predicate: predicate)
        if let model = try modelContext.fetch(descriptor).first {
            model.name = server.name
            model.host = server.host
            model.port = server.port
            model.username = server.username
            let authRaw: String
            switch server.authMethod {
            case .password: authRaw = "password"
            case .privateKey(let keyID): authRaw = "privateKey:\(keyID)"
            }
            model.authMethodRaw = authRaw
            try modelContext.save()
        }
    }

    // MARK: - Conversation Operations

    func saveConversation(_ conversation: Conversation) throws {
        let model = ConversationModel(id: conversation.id, serverID: conversation.serverID, title: conversation.title, createdAt: conversation.createdAt, updatedAt: conversation.updatedAt)
        modelContext.insert(model)
        try modelContext.save()
    }

    func fetchConversations(forServer serverID: UUID) throws -> [Conversation] {
        let predicate = #Predicate<ConversationModel> { $0.serverID == serverID }
        let descriptor = FetchDescriptor(predicate: predicate, sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        return try modelContext.fetch(descriptor).map { $0.toDomain() }
    }

    func fetchAllConversations() throws -> [Conversation] {
        let descriptor = FetchDescriptor<ConversationModel>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        return try modelContext.fetch(descriptor).map { $0.toDomain() }
    }

    func deleteConversation(_ conversationID: UUID) throws {
        let predicate = #Predicate<ConversationModel> { $0.id == conversationID }
        let descriptor = FetchDescriptor(predicate: predicate)
        if let model = try modelContext.fetch(descriptor).first {
            modelContext.delete(model)
            try modelContext.save()
        }
    }

    func addMessage(_ message: Message, toConversation conversationID: UUID) throws {
        let predicate = #Predicate<ConversationModel> { $0.id == conversationID }
        let descriptor = FetchDescriptor(predicate: predicate)
        if let conversation = try modelContext.fetch(descriptor).first {
            let messageModel = MessageModel.fromDomain(message)
            messageModel.conversation = conversation
            conversation.messages.append(messageModel)
            conversation.updatedAt = Date()
            try modelContext.save()
        }
    }

    // MARK: - Group Operations

    func saveGroup(_ group: ServerGroup) throws {
        let model = ServerGroupModel.fromDomain(group)
        modelContext.insert(model)
        try modelContext.save()
    }

    func fetchGroups() throws -> [ServerGroup] {
        let descriptor = FetchDescriptor<ServerGroupModel>(sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.createdAt)])
        return try modelContext.fetch(descriptor).map { $0.toDomain() }
    }

    func deleteGroup(_ groupID: UUID) throws {
        let predicate = #Predicate<ServerGroupModel> { $0.id == groupID }
        let descriptor = FetchDescriptor(predicate: predicate)
        if let model = try modelContext.fetch(descriptor).first {
            modelContext.delete(model)
            try modelContext.save()
        }
    }

    func updateGroup(_ group: ServerGroup) throws {
        let predicate = #Predicate<ServerGroupModel> { $0.id == group.id }
        let descriptor = FetchDescriptor(predicate: predicate)
        if let model = try modelContext.fetch(descriptor).first {
            model.name = group.name
            model.sortOrder = group.sortOrder
            model.colorTag = group.colorTag
            try modelContext.save()
        }
    }

    func assignServer(_ serverID: UUID, toGroup groupID: UUID?) throws {
        let serverPredicate = #Predicate<ServerModel> { $0.id == serverID }
        let serverDescriptor = FetchDescriptor(predicate: serverPredicate)
        guard let serverModel = try modelContext.fetch(serverDescriptor).first else { return }

        if let groupID {
            let groupPredicate = #Predicate<ServerGroupModel> { $0.id == groupID }
            let groupDescriptor = FetchDescriptor(predicate: groupPredicate)
            serverModel.group = try modelContext.fetch(groupDescriptor).first
        } else {
            serverModel.group = nil
        }
        try modelContext.save()
    }

    func fetchServersGrouped() throws -> [(group: ServerGroup?, servers: [Server])] {
        let groupDescriptor = FetchDescriptor<ServerGroupModel>(sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.createdAt)])
        let groups = try modelContext.fetch(groupDescriptor)

        let serverDescriptor = FetchDescriptor<ServerModel>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        let allServers = try modelContext.fetch(serverDescriptor)

        var result: [(group: ServerGroup?, servers: [Server])] = []

        for group in groups {
            let groupServers = allServers.filter { $0.group?.id == group.id }
            if !groupServers.isEmpty {
                result.append((group: group.toDomain(), servers: groupServers.map { $0.toDomain() }))
            }
        }

        // Ungrouped servers
        let ungrouped = allServers.filter { $0.group == nil }
        if !ungrouped.isEmpty {
            result.append((group: nil, servers: ungrouped.map { $0.toDomain() }))
        }

        return result
    }

    // MARK: - Search Operations

    func searchConversations(query: String) throws -> [ConversationSearchResult] {
        // Search by conversation title
        let titlePredicate = #Predicate<ConversationModel> { $0.title.localizedStandardContains(query) }
        let titleDescriptor = FetchDescriptor(predicate: titlePredicate)
        let titleMatches = try modelContext.fetch(titleDescriptor)

        // Search by message content
        let messagePredicate = #Predicate<MessageModel> { $0.content.localizedStandardContains(query) }
        let messageDescriptor = FetchDescriptor(predicate: messagePredicate)
        let messageMatches = try modelContext.fetch(messageDescriptor)

        var seen = Set<UUID>()
        var results: [ConversationSearchResult] = []

        // Build server lookup
        let serverDescriptor = FetchDescriptor<ServerModel>()
        let allServers = try modelContext.fetch(serverDescriptor)
        let serverLookup = Dictionary(uniqueKeysWithValues: allServers.map { ($0.id, $0.name) })

        for conv in titleMatches {
            guard !seen.contains(conv.id) else { continue }
            seen.insert(conv.id)
            let serverName = serverLookup[conv.serverID] ?? "Unknown"
            results.append(ConversationSearchResult(
                id: conv.id,
                conversationTitle: conv.title,
                serverName: serverName,
                serverID: conv.serverID,
                matchingSnippet: conv.title,
                updatedAt: conv.updatedAt
            ))
        }

        for msg in messageMatches {
            guard let conv = msg.conversation, !seen.contains(conv.id) else { continue }
            seen.insert(conv.id)
            let serverName = serverLookup[conv.serverID] ?? "Unknown"
            let snippet = String(msg.content.prefix(120))
            results.append(ConversationSearchResult(
                id: conv.id,
                conversationTitle: conv.title,
                serverName: serverName,
                serverID: conv.serverID,
                matchingSnippet: snippet,
                updatedAt: conv.updatedAt
            ))
        }

        return results.sorted { $0.updatedAt > $1.updatedAt }
    }
}
