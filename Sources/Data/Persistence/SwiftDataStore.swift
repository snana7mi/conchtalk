/// 文件说明：SwiftDataStore，统一封装 Server/Conversation/Group 的 SwiftData 持久化访问。
import Foundation
import SwiftData

/// SwiftDataStore：
/// 基于 `@ModelActor` 提供串行化数据访问边界，负责实体保存、查询、删除、分组与搜索。
@ModelActor
actor SwiftDataStore {

    // MARK: - Server Operations

    /// 保存服务器配置。
    /// - Parameter server: 待保存的服务器实体。
    /// - Throws: SwiftData 写入失败时抛出。
    /// - Side Effects: 向持久层插入一条新的 `ServerModel` 记录。
    func saveServer(_ server: Server) throws {
        let model = ServerModel.fromDomain(server)
        modelContext.insert(model)
        try modelContext.save()
    }

    /// 获取全部服务器并按创建时间倒序返回。
    /// - Returns: 服务器实体数组。
    /// - Throws: SwiftData 查询失败时抛出。
    func fetchServers() throws -> [Server] {
        let descriptor = FetchDescriptor<ServerModel>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        let models = try modelContext.fetch(descriptor)
        return models.map { $0.toDomain() }
    }

    /// 删除指定服务器。
    /// - Parameter serverID: 服务器标识。
    /// - Throws: SwiftData 查询/保存失败时抛出。
    /// - Note: 若目标不存在则静默返回，不抛出业务错误。
    /// - Side Effects: 删除服务器后，其级联关联数据按模型关系规则处理。
    func deleteServer(_ serverID: UUID) throws {
        let predicate = #Predicate<ServerModel> { $0.id == serverID }
        let descriptor = FetchDescriptor(predicate: predicate)
        if let model = try modelContext.fetch(descriptor).first {
            modelContext.delete(model)
            try modelContext.save()
        }
    }

    /// 更新服务器基础字段。
    /// - Parameter server: 包含最新字段值的服务器实体。
    /// - Throws: SwiftData 查询/保存失败时抛出。
    /// - Note: 若目标不存在则静默返回。
    /// - Side Effects: 持久层中对应服务器记录会被原地更新。
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

    /// 保存会话记录。
    /// - Parameter conversation: 待保存会话。
    /// - Throws: SwiftData 写入失败时抛出。
    /// - Side Effects: 向持久层插入一条新的 `ConversationModel`。
    func saveConversation(_ conversation: Conversation) throws {
        let model = ConversationModel(id: conversation.id, serverID: conversation.serverID, title: conversation.title, createdAt: conversation.createdAt, updatedAt: conversation.updatedAt)
        modelContext.insert(model)
        try modelContext.save()
    }

    /// 获取某台服务器下的会话列表。
    /// - Parameter serverID: 服务器标识。
    /// - Returns: 按更新时间倒序排列的会话集合。
    /// - Throws: SwiftData 查询失败时抛出。
    func fetchConversations(forServer serverID: UUID) throws -> [Conversation] {
        let predicate = #Predicate<ConversationModel> { $0.serverID == serverID }
        let descriptor = FetchDescriptor(predicate: predicate, sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        return try modelContext.fetch(descriptor).map { $0.toDomain() }
    }

    /// 获取全量会话列表。
    /// - Returns: 按更新时间倒序排列的会话集合。
    /// - Throws: SwiftData 查询失败时抛出。
    func fetchAllConversations() throws -> [Conversation] {
        let descriptor = FetchDescriptor<ConversationModel>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        return try modelContext.fetch(descriptor).map { $0.toDomain() }
    }

    /// 删除指定会话。
    /// - Parameter conversationID: 会话标识。
    /// - Throws: SwiftData 查询/保存失败时抛出。
    /// - Note: 若目标不存在则静默返回。
    /// - Side Effects: 会话及其级联消息按关系删除规则处理。
    func deleteConversation(_ conversationID: UUID) throws {
        let predicate = #Predicate<ConversationModel> { $0.id == conversationID }
        let descriptor = FetchDescriptor(predicate: predicate)
        if let model = try modelContext.fetch(descriptor).first {
            modelContext.delete(model)
            try modelContext.save()
        }
    }

    /// 向会话追加消息并刷新会话更新时间。
    /// - Parameters:
    ///   - message: 待追加消息实体。
    ///   - conversationID: 目标会话标识。
    /// - Throws: SwiftData 查询/保存失败时抛出。
    /// - Note: 若会话不存在则静默返回。
    /// - Side Effects: 会写入新消息并更新 `conversation.updatedAt`。
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

    /// 保存服务器分组。
    /// - Parameter group: 待保存分组实体。
    /// - Throws: SwiftData 写入失败时抛出。
    /// - Side Effects: 向持久层插入一条新的 `ServerGroupModel`。
    func saveGroup(_ group: ServerGroup) throws {
        let model = ServerGroupModel.fromDomain(group)
        modelContext.insert(model)
        try modelContext.save()
    }

    /// 获取全部服务器分组。
    /// - Returns: 按排序权重与创建时间排序的分组集合。
    /// - Throws: SwiftData 查询失败时抛出。
    func fetchGroups() throws -> [ServerGroup] {
        let descriptor = FetchDescriptor<ServerGroupModel>(sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.createdAt)])
        return try modelContext.fetch(descriptor).map { $0.toDomain() }
    }

    /// 删除指定分组。
    /// - Parameter groupID: 分组标识。
    /// - Throws: SwiftData 查询/保存失败时抛出。
    /// - Note: 若目标不存在则静默返回。
    /// - Side Effects: 分组删除后，服务器侧关系按 `.nullify` 规则断开。
    func deleteGroup(_ groupID: UUID) throws {
        let predicate = #Predicate<ServerGroupModel> { $0.id == groupID }
        let descriptor = FetchDescriptor(predicate: predicate)
        if let model = try modelContext.fetch(descriptor).first {
            modelContext.delete(model)
            try modelContext.save()
        }
    }

    /// 更新分组字段。
    /// - Parameter group: 含最新字段值的分组实体。
    /// - Throws: SwiftData 查询/保存失败时抛出。
    /// - Note: 若目标不存在则静默返回。
    /// - Side Effects: 持久层中对应分组记录会被原地更新。
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

    /// 调整服务器所属分组。
    /// - Parameters:
    ///   - serverID: 服务器标识。
    ///   - groupID: 目标分组标识；传 `nil` 表示取消分组。
    /// - Throws: SwiftData 查询/保存失败时抛出。
    /// - Note:
    ///   - 若服务器不存在则静默返回。
    ///   - 当 `groupID` 指向不存在分组时，服务器分组会被置空。
    /// - Side Effects: 会更新服务器与分组的关联关系。
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

    /// 按分组聚合返回服务器列表。
    /// - Returns: 元组数组；`group == nil` 表示未分组服务器集合。
    /// - Throws: SwiftData 查询失败时抛出。
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

    /// 按关键词搜索会话标题与消息正文。
    /// - Parameter query: 搜索关键词。
    /// - Returns: 去重后的命中结果，按会话更新时间倒序。
    /// - Throws: SwiftData 查询失败时抛出。
    /// - Note:
    ///   - 先匹配会话标题，再补充消息正文命中。
    ///   - 同一会话仅返回一条结果。
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
