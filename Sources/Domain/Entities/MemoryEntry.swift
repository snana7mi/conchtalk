/// 文件说明：MemoryEntry，定义细粒度记忆条目的领域实体模型。
import Foundation

/// MemoryEntry：
/// 表示从对话中提取的单条结构化记忆，包含内容、标签、实体与来源信息。
/// 以服务器为维度存储，支持语义检索与上下文注入。
nonisolated struct MemoryEntry: Identifiable, Sendable {
    let id: UUID
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
}
