/// 文件说明：SwiftDataStore，统一封装 Server/Message/Memory/Group 的 SwiftData 持久化访问。
import Foundation
import SwiftData

/// SwiftDataStore：
/// 基于 `@ModelActor` 提供串行化数据访问边界，负责实体保存、查询、删除、分组与记忆管理。
/// 移除了 Conversation 相关 CRUD，改为以 serverID 为维度直接管理消息与记忆。
@ModelActor
actor SwiftDataStore {

    // MARK: - Server Operations

    /// 保存服务器配置。
    /// - Parameter server: 待保存的服务器实体。
    /// - Throws: SwiftData 写入失败时抛出。
    /// - Side Effects: 向持久层插入一条新的 `ServerModel` 记录。
    func saveServer(_ server: Server) async throws {
        // 检查是否存在同 ID 的软删除记录（避免 @Attribute(.unique) 隐式 upsert）
        let sid = server.id
        let predicate = #Predicate<ServerModel> { $0.id == sid }
        if let existing = try modelContext.fetch(FetchDescriptor(predicate: predicate)).first {
            guard existing.isDeleted else { return }
            // 恢复软删除记录
            let fresh = ServerModel.fromDomain(server)
            existing.isDeleted = false
            existing.name = fresh.name; existing.host = fresh.host; existing.port = fresh.port
            existing.username = fresh.username; existing.authMethodRaw = fresh.authMethodRaw
            existing.countryCode = fresh.countryCode; existing.iconData = fresh.iconData
            existing.lastConnectedAt = fresh.lastConnectedAt
            existing.permissionLevelRaw = fresh.permissionLevelRaw
            existing.expirationDate = fresh.expirationDate
            existing.syncVersion = await SyncVersionCounter.shared.next()
            existing.modifiedAt = Date()
            existing.isRemoteMerge = false
            try modelContext.save()
            return
        }
        let model = ServerModel.fromDomain(server)
        model.syncVersion = await SyncVersionCounter.shared.next()
        model.modifiedAt = Date()
        model.isRemoteMerge = false
        modelContext.insert(model)
        try modelContext.save()
    }

    /// 获取全部服务器并按创建时间倒序返回。
    /// - Returns: 服务器实体数组。
    /// - Throws: SwiftData 查询失败时抛出。
    func fetchServers() throws -> [Server] {
        let descriptor = FetchDescriptor<ServerModel>(
            predicate: #Predicate { $0.isDeleted == false },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        let models = try modelContext.fetch(descriptor)
        return models.map { $0.toDomain() }
    }

    /// 删除指定服务器。
    /// - Parameter serverID: 服务器标识。
    /// - Throws: SwiftData 查询/保存失败时抛出。
    /// - Note: 若目标不存在则静默返回，不抛出业务错误。
    /// - Side Effects: 删除前清理关联的记忆、消息和系统配置。
    func deleteServer(_ serverID: UUID) async throws {
        let predicate = #Predicate<ServerModel> { $0.id == serverID }
        let descriptor = FetchDescriptor(predicate: predicate)
        if let model = try modelContext.fetch(descriptor).first {
            // 软删除：标记为已删除，等同步完成后再物理清理
            model.isDeleted = true
            model.syncVersion = await SyncVersionCounter.shared.next()
            model.modifiedAt = Date()
            model.isRemoteMerge = false

            // 同时软删除关联的记忆、消息和系统配置
            do { try await softDeleteMessages(forServer: serverID) }
            catch { print("[Message] Soft-delete failed for server=\(serverID): \(error)") }

            do { try await softDeleteMemory(forServer: serverID) }
            catch { print("[Memory] Soft-delete failed for server=\(serverID): \(error)") }

            do { try await softDeleteSystemProfile(forServer: serverID) }
            catch { print("[SystemProfile] Soft-delete failed for server=\(serverID): \(error)") }

            try modelContext.save()
        }
    }

    /// 更新服务器基础字段。
    /// - Parameter server: 包含最新字段值的服务器实体。
    /// - Throws: SwiftData 查询/保存失败时抛出。
    /// - Note: 若目标不存在则静默返回。
    /// - Side Effects: 持久层中对应服务器记录会被原地更新。
    func updateServer(_ server: Server) async throws {
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
            model.countryCode = server.countryCode
            model.iconData = server.iconData
            model.lastConnectedAt = server.lastConnectedAt
            model.permissionLevelRaw = server.permissionLevel.rawValue
            model.expirationDate = server.expirationDate
            model.syncVersion = await SyncVersionCounter.shared.next()
            model.modifiedAt = Date()
            model.isRemoteMerge = false
            try modelContext.save()
        }
    }

    /// 查询所有已过期的服务器（expirationDate 非 nil 且早于当前时间）。
    func fetchExpiredServers() throws -> [Server] {
        let now = Date()
        let descriptor = FetchDescriptor<ServerModel>(
            predicate: #Predicate { $0.isDeleted == false },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        return try modelContext.fetch(descriptor)
            .filter { guard let exp = $0.expirationDate else { return false }; return exp <= now }
            .map { $0.toDomain() }
    }

    // MARK: - Message Operations（以 serverID 为维度）

    /// 向服务器追加单条消息。
    /// - Parameters:
    ///   - message: 待追加消息实体。
    ///   - serverID: 目标服务器标识。
    /// - Throws: SwiftData 写入失败时抛出。
    /// - Note: 同 ID 消息已存在时静默跳过（幂等）。
    func addMessage(_ message: Message, toServer serverID: UUID) async throws {
        // 幂等保护：全局 ID 查找（含软删除的）避免 @Attribute(.unique) 引发的隐式 upsert
        let msgID = message.id
        let globalPredicate = #Predicate<MessageModel> { $0.id == msgID }
        guard let existing = try modelContext.fetch(FetchDescriptor(predicate: globalPredicate)).first else {
            // 全新记录 → 插入
            let messageModel = MessageModel.fromDomain(message, serverID: serverID)
            messageModel.syncVersion = await SyncVersionCounter.shared.next()
            messageModel.modifiedAt = Date()
            messageModel.isRemoteMerge = false
            modelContext.insert(messageModel)
            try modelContext.save()
            return
        }
        // 活跃记录 → 幂等跳过（无论同 server 还是跨 server）
        if !existing.isDeleted { return }
        // 跨 server 的软删除记录 → 跳过（概率 ~2^-122，不挪用归属）
        guard existing.serverID == serverID else { return }
        // 同 server 的软删除记录 → 恢复
        let fresh = MessageModel.fromDomain(message, serverID: serverID)
        existing.isDeleted = false
        existing.roleRaw = fresh.roleRaw
        existing.content = fresh.content
        existing.timestamp = fresh.timestamp
        existing.commandOutput = fresh.commandOutput
        existing.toolCallJSON = fresh.toolCallJSON
        existing.reasoningContent = fresh.reasoningContent
        existing.systemMessageTypeRaw = fresh.systemMessageTypeRaw
        existing.sourceJSON = fresh.sourceJSON
        existing.syncVersion = await SyncVersionCounter.shared.next()
        existing.modifiedAt = Date()
        existing.isRemoteMerge = false
        try modelContext.save()
    }

    /// 批量向服务器追加消息。
    /// - Parameters:
    ///   - messages: 待追加消息数组。
    ///   - serverID: 目标服务器标识。
    /// - Throws: SwiftData 写入失败时抛出。
    /// - Note: 消息数组为空或所有消息已存在时静默返回（幂等）。
    func addMessages(_ messages: [Message], toServer serverID: UUID) async throws {
        guard !messages.isEmpty else { return }

        // 全局 ID 查找（含软删除的）避免 @Attribute(.unique) 引发的隐式 upsert
        let msgIDs = messages.map(\.id)
        let existingDescriptor = FetchDescriptor<MessageModel>(
            predicate: #Predicate { msgIDs.contains($0.id) }
        )
        let existingMap = Dictionary(
            try modelContext.fetch(existingDescriptor).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var changed = false
        var insertedIDs = Set<UUID>()  // 防止同一 batch 内重复 ID 触发隐式 upsert
        for message in messages {
            guard !insertedIDs.contains(message.id) else { continue }
            if let existing = existingMap[message.id] {
                // 活跃记录 → 幂等跳过（无论同 server 还是跨 server）
                if !existing.isDeleted { continue }
                // 跨 server 的软删除记录 → 跳过（概率 ~2^-122）
                guard existing.serverID == serverID else { continue }
                // 同 server 的软删除记录 → 恢复
                let fresh = MessageModel.fromDomain(message, serverID: serverID)
                existing.isDeleted = false
                existing.roleRaw = fresh.roleRaw
                existing.content = fresh.content
                existing.timestamp = fresh.timestamp
                existing.commandOutput = fresh.commandOutput
                existing.toolCallJSON = fresh.toolCallJSON
                existing.reasoningContent = fresh.reasoningContent
                existing.systemMessageTypeRaw = fresh.systemMessageTypeRaw
                existing.sourceJSON = fresh.sourceJSON
                existing.syncVersion = await SyncVersionCounter.shared.next()
                existing.modifiedAt = Date()
                existing.isRemoteMerge = false
                changed = true
            } else {
                // 全新记录 → 插入
                let messageModel = MessageModel.fromDomain(message, serverID: serverID)
                messageModel.syncVersion = await SyncVersionCounter.shared.next()
                messageModel.modifiedAt = Date()
                messageModel.isRemoteMerge = false
                modelContext.insert(messageModel)
                insertedIDs.insert(message.id)
                changed = true
            }
        }

        if changed {
            try modelContext.save()
        }
    }

    /// 查询指定服务器的消息列表，按时间戳升序排列。
    /// - Parameters:
    ///   - serverID: 服务器标识。
    ///   - limit: 最大返回条数；0 表示不限制。
    /// - Returns: 消息实体数组。
    /// - Throws: SwiftData 查询失败时抛出。
    func fetchMessages(forServer serverID: UUID, limit: Int = 0) throws -> [Message] {
        let sid = serverID
        var descriptor = FetchDescriptor<MessageModel>(
            predicate: #Predicate { $0.serverID == sid && $0.isDeleted == false },
            sortBy: [SortDescriptor(\.timestamp)]
        )
        if limit > 0 {
            descriptor.fetchLimit = limit
        }
        return try modelContext.fetch(descriptor).map { $0.toDomain() }
    }

    /// 获取指定服务器最后一条 AI 回复消息的内容（截断到 maxLength 字符）。
    func fetchLastAssistantMessage(forServer serverID: UUID, maxLength: Int = 80) throws -> String? {
        let sid = serverID
        let assistantRole = "assistant"
        var descriptor = FetchDescriptor<MessageModel>(
            predicate: #Predicate { $0.serverID == sid && $0.roleRaw == assistantRole && $0.isDeleted == false },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        guard let model = try modelContext.fetch(descriptor).first else { return nil }
        let content = model.content
        if content.count > maxLength {
            return String(content.prefix(maxLength))
        }
        return content
    }

    // MARK: - 分页查询

    /// 获取最近 N 条消息（倒序查询后正序返回）。
    func fetchRecentMessages(forServer serverID: UUID, limit: Int) throws -> [Message] {
        let sid = serverID
        var descriptor = FetchDescriptor<MessageModel>(
            predicate: #Predicate { $0.serverID == sid && $0.isDeleted == false },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        let results = try modelContext.fetch(descriptor)
        return results.reversed().map { $0.toDomain() }
    }

    /// 获取指定游标之前的消息（用于向上翻页）。
    /// 使用 timestamp + id 复合游标避免时间戳碰撞时跳过消息。
    /// 返回结果按时间升序排列。
    func fetchOlderMessages(
        forServer serverID: UUID,
        limit: Int,
        beforeTimestamp: Date,
        beforeID: UUID
    ) throws -> [Message] {
        let sid = serverID
        let ts = beforeTimestamp

        // SwiftData #Predicate 不支持 UUID.uuidString，先按 timestamp <= ts 查询，再内存过滤
        var descriptor = FetchDescriptor<MessageModel>(
            predicate: #Predicate {
                $0.serverID == sid && $0.timestamp <= ts && $0.isDeleted == false
            },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        // 多取一些以覆盖同时间戳被过滤掉的部分
        descriptor.fetchLimit = limit + 100

        let cursorIDString = beforeID.uuidString
        let results = try modelContext.fetch(descriptor)
            .filter { model in
                // 排除游标本身及同时间戳中 ID >= 游标的消息
                if model.timestamp == ts {
                    return model.id.uuidString < cursorIDString
                }
                return true
            }
            .prefix(limit)

        return results.reversed().map { $0.toDomain() }
    }

    /// 删除指定服务器的全部消息。
    /// - Parameter serverID: 服务器标识。
    /// - Throws: SwiftData 查询/保存失败时抛出。
    func deleteMessages(forServer serverID: UUID) async throws {
        let sid = serverID
        let descriptor = FetchDescriptor<MessageModel>(predicate: #Predicate { $0.serverID == sid && $0.isDeleted == false })
        let models = try modelContext.fetch(descriptor)
        for model in models {
            model.isDeleted = true
            model.syncVersion = await SyncVersionCounter.shared.next()
            model.modifiedAt = Date()
            model.isRemoteMerge = false
        }
        if !models.isEmpty {
            try modelContext.save()
        }
    }

    // MARK: - Group Operations

    /// 保存服务器分组。
    /// - Parameter group: 待保存分组实体。
    /// - Throws: SwiftData 写入失败时抛出。
    /// - Side Effects: 向持久层插入一条新的 `ServerGroupModel`。
    func saveGroup(_ group: ServerGroup) async throws {
        let gid = group.id
        let predicate = #Predicate<ServerGroupModel> { $0.id == gid }
        if let existing = try modelContext.fetch(FetchDescriptor(predicate: predicate)).first {
            guard existing.isDeleted else { return }
            existing.isDeleted = false
            existing.name = group.name; existing.sortOrder = group.sortOrder; existing.colorTag = group.colorTag
            existing.syncVersion = await SyncVersionCounter.shared.next()
            existing.modifiedAt = Date()
            existing.isRemoteMerge = false
            try modelContext.save()
            return
        }
        let model = ServerGroupModel.fromDomain(group)
        model.syncVersion = await SyncVersionCounter.shared.next()
        model.modifiedAt = Date()
        model.isRemoteMerge = false
        modelContext.insert(model)
        try modelContext.save()
    }

    /// 获取全部服务器分组。
    /// - Returns: 按排序权重与创建时间排序的分组集合。
    /// - Throws: SwiftData 查询失败时抛出。
    func fetchGroups() throws -> [ServerGroup] {
        let descriptor = FetchDescriptor<ServerGroupModel>(
            predicate: #Predicate { $0.isDeleted == false },
            sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.createdAt)]
        )
        return try modelContext.fetch(descriptor).map { $0.toDomain() }
    }

    /// 删除指定分组。
    /// - Parameter groupID: 分组标识。
    /// - Throws: SwiftData 查询/保存失败时抛出。
    /// - Note: 若目标不存在则静默返回。
    /// - Side Effects: 分组删除后，服务器侧关系按 `.nullify` 规则断开。
    func deleteGroup(_ groupID: UUID) async throws {
        let predicate = #Predicate<ServerGroupModel> { $0.id == groupID }
        let descriptor = FetchDescriptor(predicate: predicate)
        if let model = try modelContext.fetch(descriptor).first {
            // 先解除下属 server 的分组引用，防止 server 从 UI 消失。
            // 标记为本地变更，确保解除分组操作同步到其他设备。
            for server in model.servers {
                server.group = nil
                server.syncVersion = await SyncVersionCounter.shared.next()
                server.modifiedAt = Date()
                server.isRemoteMerge = false
            }
            model.isDeleted = true
            model.syncVersion = await SyncVersionCounter.shared.next()
            model.modifiedAt = Date()
            model.isRemoteMerge = false
            try modelContext.save()
        }
    }

    /// 更新分组字段。
    /// - Parameter group: 含最新字段值的分组实体。
    /// - Throws: SwiftData 查询/保存失败时抛出。
    /// - Note: 若目标不存在则静默返回。
    /// - Side Effects: 持久层中对应分组记录会被原地更新。
    func updateGroup(_ group: ServerGroup) async throws {
        let predicate = #Predicate<ServerGroupModel> { $0.id == group.id }
        let descriptor = FetchDescriptor(predicate: predicate)
        if let model = try modelContext.fetch(descriptor).first {
            model.name = group.name
            model.sortOrder = group.sortOrder
            model.colorTag = group.colorTag
            model.syncVersion = await SyncVersionCounter.shared.next()
            model.modifiedAt = Date()
            model.isRemoteMerge = false
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
    func assignServer(_ serverID: UUID, toGroup groupID: UUID?) async throws {
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
        serverModel.syncVersion = await SyncVersionCounter.shared.next()
        serverModel.modifiedAt = Date()
        serverModel.isRemoteMerge = false
        try modelContext.save()
    }

    /// 按分组聚合返回服务器列表。
    /// - Returns: 元组数组；`group == nil` 表示未分组服务器集合。
    /// - Throws: SwiftData 查询失败时抛出。
    func fetchServersGrouped() throws -> [(group: ServerGroup?, servers: [Server])] {
        let groupDescriptor = FetchDescriptor<ServerGroupModel>(
            predicate: #Predicate { $0.isDeleted == false },
            sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.createdAt)]
        )
        let groups = try modelContext.fetch(groupDescriptor)

        let serverDescriptor = FetchDescriptor<ServerModel>(
            predicate: #Predicate { $0.isDeleted == false },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        let allServers = try modelContext.fetch(serverDescriptor)

        var result: [(group: ServerGroup?, servers: [Server])] = []

        for group in groups {
            let groupServers = allServers.filter { $0.group?.id == group.id }
            if !groupServers.isEmpty {
                result.append((group: group.toDomain(), servers: groupServers.map { $0.toDomain() }))
            }
        }

        // 未分组服务器
        let ungrouped = allServers.filter { $0.group == nil }
        if !ungrouped.isEmpty {
            result.append((group: nil, servers: ungrouped.map { $0.toDomain() }))
        }

        return result
    }

    // MARK: - Memory Operations（以 serverID 为维度）

    /// 查询指定服务器的记忆。
    /// - Parameter serverID: 服务器标识。
    /// - Returns: 记忆实体；未找到时返回 `nil`。
    /// - Throws: SwiftData 查询失败时抛出。
    func fetchMemory(forServer serverID: UUID) throws -> Memory? {
        let sid = serverID
        let predicate = #Predicate<MemoryModel> { $0.serverID == sid && $0.isDeleted == false }
        let descriptor = FetchDescriptor(predicate: predicate)
        return try modelContext.fetch(descriptor).first?.toDomain()
    }

    /// Upsert 记忆：按 serverID 查找，存在则更新，否则插入。
    /// - Parameter memory: 记忆实体。
    /// - Throws: SwiftData 查询/保存失败时抛出。
    func upsertMemory(_ memory: Memory) async throws {
        let sid = memory.serverID
        // 查找所有记录（含软删除的），用于 upsert 语义
        let predicate = #Predicate<MemoryModel> { $0.serverID == sid }
        let descriptor = FetchDescriptor(predicate: predicate)
        if let existing = try modelContext.fetch(descriptor).first {
            existing.isDeleted = false  // 恢复可能被软删除的记录
            existing.content = memory.content
            existing.updatedAt = memory.updatedAt
            existing.syncVersion = await SyncVersionCounter.shared.next()
            existing.modifiedAt = Date()
            existing.isRemoteMerge = false
        } else {
            let model = MemoryModel.fromDomain(memory)
            model.syncVersion = await SyncVersionCounter.shared.next()
            model.modifiedAt = Date()
            model.isRemoteMerge = false
            modelContext.insert(model)
        }
        try modelContext.save()
    }

    /// 删除指定服务器的记忆。目标不存在时静默成功（幂等）。
    /// - Parameter serverID: 服务器标识。
    /// - Throws: SwiftData 查询/保存失败时抛出。
    func deleteMemory(forServer serverID: UUID) async throws {
        let sid = serverID
        let predicate = #Predicate<MemoryModel> { $0.serverID == sid && $0.isDeleted == false }
        let descriptor = FetchDescriptor(predicate: predicate)
        if let model = try modelContext.fetch(descriptor).first {
            model.isDeleted = true
            model.syncVersion = await SyncVersionCounter.shared.next()
            model.modifiedAt = Date()
            model.isRemoteMerge = false
            try modelContext.save()
        }
    }

    // MARK: - MemoryEntry Operations

    /// 添加单条记忆条目。
    /// - Parameter entry: 记忆条目实体。
    /// - Throws: SwiftData 写入失败时抛出。
    func addMemoryEntry(_ entry: MemoryEntry) async throws {
        let eid = entry.id
        let predicate = #Predicate<MemoryEntryModel> { $0.id == eid }
        if let existing = try modelContext.fetch(FetchDescriptor(predicate: predicate)).first {
            guard existing.isDeleted else { return }
            existing.isDeleted = false
            existing.content = entry.content; existing.tags = entry.tags
            existing.entities = entry.entities; existing.source = entry.source
            existing.syncVersion = await SyncVersionCounter.shared.next()
            existing.modifiedAt = Date()
            existing.isRemoteMerge = false
            try modelContext.save()
            return
        }
        let model = MemoryEntryModel.fromDomain(entry)
        model.syncVersion = await SyncVersionCounter.shared.next()
        model.modifiedAt = Date()
        model.isRemoteMerge = false
        modelContext.insert(model)
        try modelContext.save()
    }

    /// 查询指定服务器的所有记忆条目，按创建时间升序。
    /// - Parameter serverID: 服务器标识。
    /// - Returns: 记忆条目数组。
    /// - Throws: SwiftData 查询失败时抛出。
    func fetchMemoryEntries(forServer serverID: UUID) throws -> [MemoryEntry] {
        let sid = serverID
        let descriptor = FetchDescriptor<MemoryEntryModel>(
            predicate: #Predicate { $0.serverID == sid && $0.isDeleted == false },
            sortBy: [SortDescriptor(\.createdAt)]
        )
        return try modelContext.fetch(descriptor).map { $0.toDomain() }
    }

    /// 删除指定 ID 的记忆条目。
    /// - Parameter entryIDs: 待删除的记忆条目 ID 数组。
    /// - Throws: SwiftData 查询/保存失败时抛出。
    func deleteMemoryEntries(_ entryIDs: [UUID]) async throws {
        guard !entryIDs.isEmpty else { return }
        let descriptor = FetchDescriptor<MemoryEntryModel>(
            predicate: #Predicate { entryIDs.contains($0.id) && $0.isDeleted == false }
        )
        let models = try modelContext.fetch(descriptor)
        for model in models {
            model.isDeleted = true
            model.syncVersion = await SyncVersionCounter.shared.next()
            model.modifiedAt = Date()
            model.isRemoteMerge = false
        }
        if !models.isEmpty {
            try modelContext.save()
        }
    }

    /// 返回指定服务器的记忆条目数量。
    /// - Parameter serverID: 服务器标识。
    /// - Returns: 条目总数。
    /// - Throws: SwiftData 查询失败时抛出。
    func memoryEntryCount(forServer serverID: UUID) throws -> Int {
        let sid = serverID
        let descriptor = FetchDescriptor<MemoryEntryModel>(
            predicate: #Predicate { $0.serverID == sid && $0.isDeleted == false }
        )
        return try modelContext.fetchCount(descriptor)
    }

    // MARK: - SystemProfile Operations

    /// 按 serverID 查询系统环境探测结果。
    func fetchSystemProfile(forServer serverID: UUID) throws -> SystemProfile? {
        let predicate = #Predicate<SystemProfileModel> { $0.serverID == serverID && $0.isDeleted == false }
        let descriptor = FetchDescriptor(predicate: predicate)
        guard let model = try modelContext.fetch(descriptor).first else { return nil }
        do {
            return try model.toDomain()
        } catch {
            print("[SystemProfile] Failed to decode profile for server=\(serverID): \(error)")
            throw error
        }
    }

    /// Upsert 系统环境探测结果：按 serverID 查找，存在则更新，否则插入。
    func upsertSystemProfile(_ profile: SystemProfile) async throws {
        let sid = profile.serverID
        let predicate = #Predicate<SystemProfileModel> { $0.serverID == sid }
        let descriptor = FetchDescriptor(predicate: predicate)
        if let existing = try modelContext.fetch(descriptor).first {
            existing.isDeleted = false  // 恢复可能被软删除的记录
            existing.osInfo = profile.osInfo
            existing.packageManager = profile.packageManager
            guard let data = try? JSONEncoder().encode(profile.installedTools),
                  let json = String(data: data, encoding: .utf8) else {
                print("[SystemProfile] Failed to encode profile tools for server=\(sid)")
                throw SystemProfileModelError.toolsEncodingFailed
            }
            existing.toolsJSON = json
            existing.detectedAt = profile.detectedAt
            existing.syncVersion = await SyncVersionCounter.shared.next()
            existing.modifiedAt = Date()
            existing.isRemoteMerge = false
        } else {
            do {
                let model = try SystemProfileModel.fromDomain(profile)
                model.syncVersion = await SyncVersionCounter.shared.next()
                model.modifiedAt = Date()
                model.isRemoteMerge = false
                modelContext.insert(model)
            } catch {
                print("[SystemProfile] Failed to create profile model for server=\(sid): \(error)")
                throw error
            }
        }
        try modelContext.save()
    }

    /// 删除指定服务器的系统环境探测结果。
    func deleteSystemProfile(forServer serverID: UUID) async throws {
        let predicate = #Predicate<SystemProfileModel> { $0.serverID == serverID && $0.isDeleted == false }
        let descriptor = FetchDescriptor(predicate: predicate)
        if let model = try modelContext.fetch(descriptor).first {
            model.isDeleted = true
            model.syncVersion = await SyncVersionCounter.shared.next()
            model.modifiedAt = Date()
            model.isRemoteMerge = false
            try modelContext.save()
        }
    }

    // MARK: - SSHKey Operations

    /// 保存 SSH 密钥。
    /// - Parameter key: 待保存的密钥实体。
    /// - Throws: SwiftData 写入失败时抛出。
    /// - Side Effects: 向持久层插入一条新的 `SSHKeyModel` 记录。
    func saveSSHKey(_ key: SSHKey) async throws {
        let kid = key.id
        let predicate = #Predicate<SSHKeyModel> { $0.id == kid }
        if let existing = try modelContext.fetch(FetchDescriptor(predicate: predicate)).first {
            guard existing.isDeleted else { return }
            existing.isDeleted = false
            existing.label = key.label; existing.keyTypeRaw = key.keyType.rawValue
            existing.fingerprint = key.fingerprint; existing.publicKeyOpenSSH = key.publicKeyOpenSSH
            existing.sourceRaw = key.source.rawValue
            existing.syncVersion = await SyncVersionCounter.shared.next()
            existing.modifiedAt = Date()
            existing.isRemoteMerge = false
            try modelContext.save()
            return
        }
        let model = SSHKeyModel.fromDomain(key)
        model.syncVersion = await SyncVersionCounter.shared.next()
        model.modifiedAt = Date()
        model.isRemoteMerge = false
        modelContext.insert(model)
        try modelContext.save()
    }

    /// 获取全部 SSH 密钥并按创建时间倒序返回。
    /// - Returns: 密钥实体数组。
    /// - Throws: SwiftData 查询失败时抛出。
    func fetchSSHKeys() throws -> [SSHKey] {
        let descriptor = FetchDescriptor<SSHKeyModel>(
            predicate: #Predicate { $0.isDeleted == false },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        let models = try modelContext.fetch(descriptor)
        return models.map { $0.toDomain() }
    }

    /// 按标识获取单个 SSH 密钥。
    /// - Parameter keyID: 密钥标识。
    /// - Returns: 匹配的密钥实体，未找到时返回 `nil`。
    /// - Throws: SwiftData 查询失败时抛出。
    func fetchSSHKey(byID keyID: UUID) throws -> SSHKey? {
        let predicate = #Predicate<SSHKeyModel> { $0.id == keyID && $0.isDeleted == false }
        let descriptor = FetchDescriptor(predicate: predicate)
        return try modelContext.fetch(descriptor).first?.toDomain()
    }

    /// 更新 SSH 密钥可变字段。
    /// - Parameter key: 包含最新字段值的密钥实体。
    /// - Throws: SwiftData 查询/保存失败时抛出。
    /// - Note: 若目标不存在则静默返回。
    /// - Side Effects: 持久层中对应密钥记录会被原地更新。
    func updateSSHKey(_ key: SSHKey) async throws {
        let predicate = #Predicate<SSHKeyModel> { $0.id == key.id }
        let descriptor = FetchDescriptor(predicate: predicate)
        if let model = try modelContext.fetch(descriptor).first {
            model.label = key.label
            model.keyTypeRaw = key.keyType.rawValue
            model.fingerprint = key.fingerprint
            model.publicKeyOpenSSH = key.publicKeyOpenSSH
            model.sourceRaw = key.source.rawValue
            model.syncVersion = await SyncVersionCounter.shared.next()
            model.modifiedAt = Date()
            model.isRemoteMerge = false
            try modelContext.save()
        }
    }

    /// 删除指定 SSH 密钥。
    /// - Parameter keyID: 密钥标识。
    /// - Throws: SwiftData 查询/保存失败时抛出。
    /// - Note: 若目标不存在则静默返回，不抛出业务错误。
    /// - Side Effects: 删除密钥后相关 Keychain 条目需由调用方单独清理。
    func deleteSSHKey(_ keyID: UUID) async throws {
        let predicate = #Predicate<SSHKeyModel> { $0.id == keyID }
        let descriptor = FetchDescriptor(predicate: predicate)
        if let model = try modelContext.fetch(descriptor).first {
            model.isDeleted = true
            model.syncVersion = await SyncVersionCounter.shared.next()
            model.modifiedAt = Date()
            model.isRemoteMerge = false
            try modelContext.save()
        }
    }

    // MARK: - Sync: Soft Delete Helpers

    /// 软删除指定服务器的全部消息。
    private func softDeleteMessages(forServer serverID: UUID) async throws {
        let sid = serverID
        let descriptor = FetchDescriptor<MessageModel>(predicate: #Predicate { $0.serverID == sid && $0.isDeleted == false })
        let models = try modelContext.fetch(descriptor)
        for model in models {
            model.isDeleted = true
            model.syncVersion = await SyncVersionCounter.shared.next()
            model.modifiedAt = Date()
            model.isRemoteMerge = false
        }
    }

    /// 软删除指定服务器的记忆。
    private func softDeleteMemory(forServer serverID: UUID) async throws {
        let sid = serverID
        let predicate = #Predicate<MemoryModel> { $0.serverID == sid && $0.isDeleted == false }
        let descriptor = FetchDescriptor(predicate: predicate)
        if let model = try modelContext.fetch(descriptor).first {
            model.isDeleted = true
            model.syncVersion = await SyncVersionCounter.shared.next()
            model.modifiedAt = Date()
            model.isRemoteMerge = false
        }
    }

    /// 软删除指定服务器的系统配置。
    private func softDeleteSystemProfile(forServer serverID: UUID) async throws {
        let predicate = #Predicate<SystemProfileModel> { $0.serverID == serverID && $0.isDeleted == false }
        let descriptor = FetchDescriptor(predicate: predicate)
        if let model = try modelContext.fetch(descriptor).first {
            model.isDeleted = true
            model.syncVersion = await SyncVersionCounter.shared.next()
            model.modifiedAt = Date()
            model.isRemoteMerge = false
        }
    }

    // MARK: - Sync: Purge Soft-Deleted Entities

    /// 物理清理本地已软删除超过指定时间的记录。
    func purgeSoftDeletedEntities(olderThan interval: TimeInterval) throws {
        let cutoff = Date().addingTimeInterval(-interval)

        // Server
        let serverDesc = FetchDescriptor<ServerModel>(predicate: #Predicate { $0.isDeleted == true && $0.modifiedAt < cutoff })
        for model in try modelContext.fetch(serverDesc) { modelContext.delete(model) }

        // Message
        let msgDesc = FetchDescriptor<MessageModel>(predicate: #Predicate { $0.isDeleted == true && $0.modifiedAt < cutoff })
        for model in try modelContext.fetch(msgDesc) { modelContext.delete(model) }

        // SSHKey
        let keyDesc = FetchDescriptor<SSHKeyModel>(predicate: #Predicate { $0.isDeleted == true && $0.modifiedAt < cutoff })
        for model in try modelContext.fetch(keyDesc) { modelContext.delete(model) }

        // ServerGroup
        let groupDesc = FetchDescriptor<ServerGroupModel>(predicate: #Predicate { $0.isDeleted == true && $0.modifiedAt < cutoff })
        for model in try modelContext.fetch(groupDesc) { modelContext.delete(model) }

        // Memory
        let memDesc = FetchDescriptor<MemoryModel>(predicate: #Predicate { $0.isDeleted == true && $0.modifiedAt < cutoff })
        for model in try modelContext.fetch(memDesc) { modelContext.delete(model) }

        // MemoryEntry
        let entryDesc = FetchDescriptor<MemoryEntryModel>(predicate: #Predicate { $0.isDeleted == true && $0.modifiedAt < cutoff })
        for model in try modelContext.fetch(entryDesc) { modelContext.delete(model) }

        // SystemProfile
        let profDesc = FetchDescriptor<SystemProfileModel>(predicate: #Predicate { $0.isDeleted == true && $0.modifiedAt < cutoff })
        for model in try modelContext.fetch(profDesc) { modelContext.delete(model) }

        try modelContext.save()
    }

    // MARK: - Sync: Fetch Changed Entities

    /// 可同步的服务器快照（含密码，整体加密后上传）。
    struct SyncableServer: Codable, Sendable {
        let id: UUID; let name: String; let host: String; let port: Int; let username: String
        let authMethodRaw: String; let countryCode: String?; let iconData: Data?
        let lastConnectedAt: Date?; let permissionLevelRaw: String; let expirationDate: Date?
        let createdAt: Date; let syncVersion: Int64; let modifiedAt: Date; let isDeleted: Bool
        let isRemoteMerge: Bool; let groupID: UUID?
        let password: String?  // 从 Keychain 读取，随实体一起加密上传
    }

    func fetchChangedServers(since syncVersion: Int64, limit: Int) throws -> [SyncableServer] {
        let predicate = #Predicate<ServerModel> { $0.syncVersion > syncVersion && $0.isRemoteMerge == false }
        var descriptor = FetchDescriptor(predicate: predicate, sortBy: [SortDescriptor(\.syncVersion)])
        descriptor.fetchLimit = limit
        return try modelContext.fetch(descriptor).map {
            SyncableServer(id: $0.id, name: $0.name, host: $0.host, port: $0.port, username: $0.username,
                          authMethodRaw: $0.authMethodRaw, countryCode: $0.countryCode, iconData: $0.iconData,
                          lastConnectedAt: $0.lastConnectedAt, permissionLevelRaw: $0.permissionLevelRaw,
                          expirationDate: $0.expirationDate, createdAt: $0.createdAt,
                          syncVersion: $0.syncVersion, modifiedAt: $0.modifiedAt, isDeleted: $0.isDeleted,
                          isRemoteMerge: $0.isRemoteMerge, groupID: $0.group?.id, password: nil)
        }
    }

    /// 可同步的消息快照。
    struct SyncableMessage: Codable, Sendable {
        let id: UUID; let serverID: UUID; let roleRaw: String; let content: String
        let timestamp: Date; let commandOutput: String?; let toolCallJSON: Data?
        let reasoningContent: String?; let systemMessageTypeRaw: String?; let sourceJSON: Data?
        let syncVersion: Int64; let modifiedAt: Date; let isDeleted: Bool; let isRemoteMerge: Bool
    }

    func fetchChangedMessages(since syncVersion: Int64, limit: Int) throws -> [SyncableMessage] {
        let predicate = #Predicate<MessageModel> { $0.syncVersion > syncVersion && $0.isRemoteMerge == false }
        var descriptor = FetchDescriptor(predicate: predicate, sortBy: [SortDescriptor(\.syncVersion)])
        descriptor.fetchLimit = limit
        return try modelContext.fetch(descriptor).map {
            SyncableMessage(id: $0.id, serverID: $0.serverID, roleRaw: $0.roleRaw, content: $0.content,
                           timestamp: $0.timestamp, commandOutput: $0.commandOutput, toolCallJSON: $0.toolCallJSON,
                           reasoningContent: $0.reasoningContent, systemMessageTypeRaw: $0.systemMessageTypeRaw,
                           sourceJSON: $0.sourceJSON, syncVersion: $0.syncVersion, modifiedAt: $0.modifiedAt,
                           isDeleted: $0.isDeleted, isRemoteMerge: $0.isRemoteMerge)
        }
    }

    /// 可同步的 SSH 密钥快照（含加密后的私钥数据）。
    struct SyncableSSHKey: Codable, Sendable {
        let id: UUID; let label: String; let keyTypeRaw: String; let fingerprint: String
        let publicKeyOpenSSH: String; let sourceRaw: String; let createdAt: Date
        let privateKeyData: Data?  // 从 Keychain 读取的私钥，加密后同步
        let syncVersion: Int64; let modifiedAt: Date; let isDeleted: Bool; let isRemoteMerge: Bool
    }

    func fetchChangedSSHKeys(since syncVersion: Int64, limit: Int) throws -> [SyncableSSHKey] {
        let predicate = #Predicate<SSHKeyModel> { $0.syncVersion > syncVersion && $0.isRemoteMerge == false }
        var descriptor = FetchDescriptor(predicate: predicate, sortBy: [SortDescriptor(\.syncVersion)])
        descriptor.fetchLimit = limit
        return try modelContext.fetch(descriptor).map {
            SyncableSSHKey(id: $0.id, label: $0.label, keyTypeRaw: $0.keyTypeRaw, fingerprint: $0.fingerprint,
                          publicKeyOpenSSH: $0.publicKeyOpenSSH, sourceRaw: $0.sourceRaw, createdAt: $0.createdAt,
                          privateKeyData: nil, syncVersion: $0.syncVersion, modifiedAt: $0.modifiedAt,
                          isDeleted: $0.isDeleted, isRemoteMerge: $0.isRemoteMerge)
        }
    }

    /// 可同步的服务器分组快照。
    struct SyncableServerGroup: Codable, Sendable {
        let id: UUID; let name: String; let sortOrder: Int; let colorTag: String?; let createdAt: Date
        let syncVersion: Int64; let modifiedAt: Date; let isDeleted: Bool; let isRemoteMerge: Bool
    }

    func fetchChangedServerGroups(since syncVersion: Int64, limit: Int) throws -> [SyncableServerGroup] {
        let predicate = #Predicate<ServerGroupModel> { $0.syncVersion > syncVersion && $0.isRemoteMerge == false }
        var descriptor = FetchDescriptor(predicate: predicate, sortBy: [SortDescriptor(\.syncVersion)])
        descriptor.fetchLimit = limit
        return try modelContext.fetch(descriptor).map {
            SyncableServerGroup(id: $0.id, name: $0.name, sortOrder: $0.sortOrder, colorTag: $0.colorTag,
                               createdAt: $0.createdAt, syncVersion: $0.syncVersion, modifiedAt: $0.modifiedAt,
                               isDeleted: $0.isDeleted, isRemoteMerge: $0.isRemoteMerge)
        }
    }

    /// 可同步的记忆快照。
    struct SyncableMemory: Codable, Sendable {
        let id: UUID; let serverID: UUID; let content: String; let updatedAt: Date
        let syncVersion: Int64; let modifiedAt: Date; let isDeleted: Bool; let isRemoteMerge: Bool
    }

    func fetchChangedMemories(since syncVersion: Int64, limit: Int) throws -> [SyncableMemory] {
        let predicate = #Predicate<MemoryModel> { $0.syncVersion > syncVersion && $0.isRemoteMerge == false }
        var descriptor = FetchDescriptor(predicate: predicate, sortBy: [SortDescriptor(\.syncVersion)])
        descriptor.fetchLimit = limit
        return try modelContext.fetch(descriptor).map {
            SyncableMemory(id: $0.id, serverID: $0.serverID, content: $0.content, updatedAt: $0.updatedAt,
                          syncVersion: $0.syncVersion, modifiedAt: $0.modifiedAt, isDeleted: $0.isDeleted,
                          isRemoteMerge: $0.isRemoteMerge)
        }
    }

    /// 可同步的记忆条目快照。
    struct SyncableMemoryEntry: Codable, Sendable {
        let id: UUID; let serverID: UUID; let content: String; let tags: [String]; let entities: [String]
        let createdAt: Date; let source: String
        let syncVersion: Int64; let modifiedAt: Date; let isDeleted: Bool; let isRemoteMerge: Bool
    }

    func fetchChangedMemoryEntries(since syncVersion: Int64, limit: Int) throws -> [SyncableMemoryEntry] {
        let predicate = #Predicate<MemoryEntryModel> { $0.syncVersion > syncVersion && $0.isRemoteMerge == false }
        var descriptor = FetchDescriptor(predicate: predicate, sortBy: [SortDescriptor(\.syncVersion)])
        descriptor.fetchLimit = limit
        return try modelContext.fetch(descriptor).map {
            SyncableMemoryEntry(id: $0.id, serverID: $0.serverID, content: $0.content, tags: $0.tags,
                               entities: $0.entities, createdAt: $0.createdAt, source: $0.source,
                               syncVersion: $0.syncVersion, modifiedAt: $0.modifiedAt, isDeleted: $0.isDeleted,
                               isRemoteMerge: $0.isRemoteMerge)
        }
    }

    /// 可同步的系统画像快照。
    struct SyncableSystemProfile: Codable, Sendable {
        let serverID: UUID; let osInfo: String; let packageManager: String?; let toolsJSON: String
        let detectedAt: Date
        let syncVersion: Int64; let modifiedAt: Date; let isDeleted: Bool; let isRemoteMerge: Bool
    }

    func fetchChangedSystemProfiles(since syncVersion: Int64, limit: Int) throws -> [SyncableSystemProfile] {
        let predicate = #Predicate<SystemProfileModel> { $0.syncVersion > syncVersion && $0.isRemoteMerge == false }
        var descriptor = FetchDescriptor(predicate: predicate, sortBy: [SortDescriptor(\.syncVersion)])
        descriptor.fetchLimit = limit
        return try modelContext.fetch(descriptor).map {
            SyncableSystemProfile(serverID: $0.serverID, osInfo: $0.osInfo, packageManager: $0.packageManager,
                                 toolsJSON: $0.toolsJSON, detectedAt: $0.detectedAt,
                                 syncVersion: $0.syncVersion, modifiedAt: $0.modifiedAt, isDeleted: $0.isDeleted,
                                 isRemoteMerge: $0.isRemoteMerge)
        }
    }

    // MARK: - Sync: Merge Remote Entities (LWW)

    /// 合并远端服务器数据：按 id 匹配，modifiedAt 较新者胜出。
    /// 合入的数据标记 isRemoteMerge = true，避免 ping-pong 二次推送。
    func mergeRemoteServer(_ remote: SyncableServer) async throws -> Int {
        let predicate = #Predicate<ServerModel> { $0.id == remote.id }
        let existing = try modelContext.fetch(FetchDescriptor(predicate: predicate)).first

        if let existing {
            if remote.modifiedAt > existing.modifiedAt {
                if remote.isDeleted {
                    existing.isDeleted = true
                } else {
                    existing.isDeleted = false
                    existing.name = remote.name
                    existing.host = remote.host
                    existing.port = remote.port
                    existing.username = remote.username
                    existing.authMethodRaw = remote.authMethodRaw
                    existing.countryCode = remote.countryCode
                    existing.iconData = remote.iconData
                    existing.lastConnectedAt = remote.lastConnectedAt
                    existing.permissionLevelRaw = remote.permissionLevelRaw
                    existing.expirationDate = remote.expirationDate
                }
                existing.modifiedAt = remote.modifiedAt
                existing.syncVersion = await SyncVersionCounter.shared.next()
                existing.isRemoteMerge = true
                // 重建分组关系
                if let groupID = remote.groupID {
                    let gid = groupID
                    let groupPredicate = #Predicate<ServerGroupModel> { $0.id == gid }
                    existing.group = try modelContext.fetch(FetchDescriptor(predicate: groupPredicate)).first
                } else {
                    existing.group = nil
                }
                try modelContext.save()
                return 1
            }
        } else if !remote.isDeleted {
            let model = ServerModel(id: remote.id, name: remote.name, host: remote.host, port: remote.port,
                                   username: remote.username, authMethodRaw: remote.authMethodRaw,
                                   countryCode: remote.countryCode, iconData: remote.iconData,
                                   lastConnectedAt: remote.lastConnectedAt, permissionLevelRaw: remote.permissionLevelRaw,
                                   expirationDate: remote.expirationDate, createdAt: remote.createdAt)
            model.modifiedAt = remote.modifiedAt
            model.syncVersion = await SyncVersionCounter.shared.next()
            model.isRemoteMerge = true
            // 重建分组关系
            if let groupID = remote.groupID {
                let gid = groupID
                let groupPredicate = #Predicate<ServerGroupModel> { $0.id == gid }
                model.group = try modelContext.fetch(FetchDescriptor(predicate: groupPredicate)).first
            }
            modelContext.insert(model)
            try modelContext.save()
            return 1
        }
        return 0
    }

    /// 合并远端消息数据。
    func mergeRemoteMessage(_ remote: SyncableMessage) async throws -> (merged: Int, conflicts: Int) {
        let predicate = #Predicate<MessageModel> { $0.id == remote.id }
        let existing = try modelContext.fetch(FetchDescriptor(predicate: predicate)).first

        if let existing {
            if remote.modifiedAt > existing.modifiedAt {
                if remote.isDeleted {
                    existing.isDeleted = true
                } else {
                    existing.isDeleted = false
                    existing.content = remote.content
                    existing.roleRaw = remote.roleRaw
                    existing.commandOutput = remote.commandOutput
                    existing.toolCallJSON = remote.toolCallJSON
                    existing.reasoningContent = remote.reasoningContent
                    existing.systemMessageTypeRaw = remote.systemMessageTypeRaw
                    existing.sourceJSON = remote.sourceJSON
                }
                existing.modifiedAt = remote.modifiedAt
                existing.syncVersion = await SyncVersionCounter.shared.next()
                existing.isRemoteMerge = true
                try modelContext.save()
                return (merged: 1, conflicts: 0)
            }
        } else if !remote.isDeleted {
            let model = MessageModel(id: remote.id, serverID: remote.serverID, roleRaw: remote.roleRaw,
                                    content: remote.content, timestamp: remote.timestamp,
                                    commandOutput: remote.commandOutput, toolCallJSON: remote.toolCallJSON,
                                    reasoningContent: remote.reasoningContent, systemMessageTypeRaw: remote.systemMessageTypeRaw,
                                    sourceJSON: remote.sourceJSON)
            model.modifiedAt = remote.modifiedAt
            model.syncVersion = await SyncVersionCounter.shared.next()
            model.isRemoteMerge = true
            modelContext.insert(model)
            try modelContext.save()
            return (merged: 1, conflicts: 0)
        }
        return (merged: 0, conflicts: 0)
    }

    /// 合并远端 SSH 密钥。
    func mergeRemoteSSHKey(_ remote: SyncableSSHKey) async throws -> Int {
        let predicate = #Predicate<SSHKeyModel> { $0.id == remote.id }
        let existing = try modelContext.fetch(FetchDescriptor(predicate: predicate)).first

        if let existing {
            if remote.modifiedAt > existing.modifiedAt {
                if remote.isDeleted { existing.isDeleted = true }
                else {
                    existing.isDeleted = false
                    existing.label = remote.label
                    existing.keyTypeRaw = remote.keyTypeRaw
                    existing.fingerprint = remote.fingerprint
                    existing.publicKeyOpenSSH = remote.publicKeyOpenSSH
                    existing.sourceRaw = remote.sourceRaw
                }
                existing.modifiedAt = remote.modifiedAt
                existing.syncVersion = await SyncVersionCounter.shared.next()
                existing.isRemoteMerge = true
                try modelContext.save()
                return 1
            }
        } else if !remote.isDeleted {
            let model = SSHKeyModel(id: remote.id, label: remote.label, keyTypeRaw: remote.keyTypeRaw,
                                   fingerprint: remote.fingerprint, publicKeyOpenSSH: remote.publicKeyOpenSSH,
                                   sourceRaw: remote.sourceRaw, createdAt: remote.createdAt)
            model.modifiedAt = remote.modifiedAt
            model.syncVersion = await SyncVersionCounter.shared.next()
            model.isRemoteMerge = true
            modelContext.insert(model)
            try modelContext.save()
            return 1
        }
        return 0
    }

    /// 合并远端服务器分组。
    func mergeRemoteServerGroup(_ remote: SyncableServerGroup) async throws -> (merged: Int, conflicts: Int) {
        let predicate = #Predicate<ServerGroupModel> { $0.id == remote.id }
        let existing = try modelContext.fetch(FetchDescriptor(predicate: predicate)).first

        if let existing {
            if remote.modifiedAt > existing.modifiedAt {
                if remote.isDeleted { existing.isDeleted = true }
                else {
                    existing.isDeleted = false
                    existing.name = remote.name
                    existing.sortOrder = remote.sortOrder
                    existing.colorTag = remote.colorTag
                }
                existing.modifiedAt = remote.modifiedAt
                existing.syncVersion = await SyncVersionCounter.shared.next()
                existing.isRemoteMerge = true
                try modelContext.save()
                return (merged: 1, conflicts: 0)
            }
        } else if !remote.isDeleted {
            let model = ServerGroupModel(id: remote.id, name: remote.name, sortOrder: remote.sortOrder,
                                        colorTag: remote.colorTag, createdAt: remote.createdAt)
            model.modifiedAt = remote.modifiedAt
            model.syncVersion = await SyncVersionCounter.shared.next()
            model.isRemoteMerge = true
            modelContext.insert(model)
            try modelContext.save()
            return (merged: 1, conflicts: 0)
        }
        return (merged: 0, conflicts: 0)
    }

    /// 合并远端记忆。
    func mergeRemoteMemory(_ remote: SyncableMemory) async throws -> (merged: Int, conflicts: Int) {
        let remoteServerID = remote.serverID
        let predicate = #Predicate<MemoryModel> { $0.serverID == remoteServerID }
        let existing = try modelContext.fetch(FetchDescriptor(predicate: predicate)).first

        if let existing {
            if remote.modifiedAt > existing.modifiedAt {
                if remote.isDeleted { existing.isDeleted = true }
                else { existing.isDeleted = false; existing.content = remote.content; existing.updatedAt = remote.updatedAt }
                existing.modifiedAt = remote.modifiedAt
                existing.syncVersion = await SyncVersionCounter.shared.next()
                existing.isRemoteMerge = true
                try modelContext.save()
                return (merged: 1, conflicts: 0)
            }
        } else if !remote.isDeleted {
            let model = MemoryModel(id: remote.id, serverID: remote.serverID, content: remote.content, updatedAt: remote.updatedAt)
            model.modifiedAt = remote.modifiedAt
            model.syncVersion = await SyncVersionCounter.shared.next()
            model.isRemoteMerge = true
            modelContext.insert(model)
            try modelContext.save()
            return (merged: 1, conflicts: 0)
        }
        return (merged: 0, conflicts: 0)
    }

    /// 合并远端记忆条目。
    func mergeRemoteMemoryEntry(_ remote: SyncableMemoryEntry) async throws -> (merged: Int, conflicts: Int) {
        let predicate = #Predicate<MemoryEntryModel> { $0.id == remote.id }
        let existing = try modelContext.fetch(FetchDescriptor(predicate: predicate)).first

        if let existing {
            if remote.modifiedAt > existing.modifiedAt {
                if remote.isDeleted { existing.isDeleted = true }
                else {
                    existing.isDeleted = false
                    existing.content = remote.content
                    existing.tags = remote.tags
                    existing.entities = remote.entities
                    existing.source = remote.source
                }
                existing.modifiedAt = remote.modifiedAt
                existing.syncVersion = await SyncVersionCounter.shared.next()
                existing.isRemoteMerge = true
                try modelContext.save()
                return (merged: 1, conflicts: 0)
            }
        } else if !remote.isDeleted {
            let model = MemoryEntryModel(id: remote.id, serverID: remote.serverID, content: remote.content,
                                        tags: remote.tags, entities: remote.entities, createdAt: remote.createdAt, source: remote.source)
            model.modifiedAt = remote.modifiedAt
            model.syncVersion = await SyncVersionCounter.shared.next()
            model.isRemoteMerge = true
            modelContext.insert(model)
            try modelContext.save()
            return (merged: 1, conflicts: 0)
        }
        return (merged: 0, conflicts: 0)
    }

    /// 合并远端系统画像。
    func mergeRemoteSystemProfile(_ remote: SyncableSystemProfile) async throws -> (merged: Int, conflicts: Int) {
        let remoteServerID = remote.serverID
        let predicate = #Predicate<SystemProfileModel> { $0.serverID == remoteServerID }
        let existing = try modelContext.fetch(FetchDescriptor(predicate: predicate)).first

        if let existing {
            if remote.modifiedAt > existing.modifiedAt {
                if remote.isDeleted { existing.isDeleted = true }
                else {
                    existing.isDeleted = false
                    existing.osInfo = remote.osInfo
                    existing.packageManager = remote.packageManager
                    existing.toolsJSON = remote.toolsJSON
                    existing.detectedAt = remote.detectedAt
                }
                existing.modifiedAt = remote.modifiedAt
                existing.syncVersion = await SyncVersionCounter.shared.next()
                existing.isRemoteMerge = true
                try modelContext.save()
                return (merged: 1, conflicts: 0)
            }
        } else if !remote.isDeleted {
            let model = SystemProfileModel(serverID: remote.serverID, osInfo: remote.osInfo,
                                          packageManager: remote.packageManager, toolsJSON: remote.toolsJSON,
                                          detectedAt: remote.detectedAt)
            model.modifiedAt = remote.modifiedAt
            model.syncVersion = await SyncVersionCounter.shared.next()
            model.isRemoteMerge = true
            modelContext.insert(model)
            try modelContext.save()
            return (merged: 1, conflicts: 0)
        }
        return (merged: 0, conflicts: 0)
    }

    // MARK: - Sync: Rebuild Relationships

    /// 全量恢复后重建 Server ↔ ServerGroup 关系（兜底方案）。
    /// 全量恢复后重建 Server ↔ ServerGroup 关系。
    /// 接收 serverID → groupID 映射（从 sync payload 中提取），
    /// 扫描 group 为 nil 的 server，按映射关联到对应的 ServerGroupModel。
    /// - Parameter mappings: serverID → groupID 映射表。
    func rebuildServerGroupRelationships(mappings: [UUID: UUID]) throws {
        guard !mappings.isEmpty else { return }

        let allServers = try modelContext.fetch(FetchDescriptor<ServerModel>(
            predicate: #Predicate { $0.isDeleted == false }
        ))
        let orphans = allServers.filter { $0.group == nil }
        guard !orphans.isEmpty else { return }

        // 预加载所有 group，构建 ID → model 映射
        let allGroups = try modelContext.fetch(FetchDescriptor<ServerGroupModel>(
            predicate: #Predicate { $0.isDeleted == false }
        ))
        let groupMap = Dictionary(allGroups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var fixed = 0
        for server in orphans {
            guard let targetGroupID = mappings[server.id],
                  let group = groupMap[targetGroupID] else { continue }
            server.group = group
            fixed += 1
        }

        if fixed > 0 {
            try modelContext.save()
            print("[Sync] Rebuilt \(fixed) server-group relationships")
        }
    }
}
