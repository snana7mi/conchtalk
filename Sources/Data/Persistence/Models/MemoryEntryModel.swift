/// 文件说明：MemoryEntryModel，定义单条记忆条目在 SwiftData 中的持久化结构。
import Foundation
import SwiftData

/// MemoryEntryModel：
/// 细粒度记忆条目持久化模型，每条记录对应一个从对话中提取的事实或实体。
/// 通过 serverID 关联服务器，支持按标签和实体检索。
@Model
final class MemoryEntryModel {
    @Attribute(.unique) var id: UUID
    /// 关联的服务器 ID。
    var serverID: UUID
    /// 记忆内容文本。
    var content: String
    /// 标签列表，用于分类检索。
    var tags: [String]
    /// 提及的实体（人名、服务名、路径等）。
    var entities: [String]
    /// 创建时间。
    var createdAt: Date
    /// 来源描述（如 "conversation"、"user_input" 等）。
    var source: String

    // MARK: - 同步字段
    var syncVersion: Int64 = 0
    var modifiedAt: Date = Date()
    var isDeleted: Bool = false
    var isRemoteMerge: Bool = false

    init(
        id: UUID = UUID(),
        serverID: UUID,
        content: String,
        tags: [String] = [],
        entities: [String] = [],
        createdAt: Date = Date(),
        source: String = "conversation"
    ) {
        self.id = id
        self.serverID = serverID
        self.content = content
        self.tags = tags
        self.entities = entities
        self.createdAt = createdAt
        self.source = source
    }

    /// 转换为领域层 `MemoryEntry` 实体。
    func toDomain() -> MemoryEntry {
        MemoryEntry(
            id: id,
            serverID: serverID,
            content: content,
            tags: tags,
            entities: entities,
            createdAt: createdAt,
            source: source
        )
    }

    /// 从领域层 `MemoryEntry` 构建持久化模型。
    static func fromDomain(_ entry: MemoryEntry) -> MemoryEntryModel {
        MemoryEntryModel(
            id: entry.id,
            serverID: entry.serverID,
            content: entry.content,
            tags: entry.tags,
            entities: entry.entities,
            createdAt: entry.createdAt,
            source: entry.source
        )
    }
}
