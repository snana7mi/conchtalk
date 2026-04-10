/// 文件说明：Memory，定义服务器级记忆的领域实体模型。
import Foundation

/// Memory：
/// 表示 AI 跨对话记忆的单条记录，以服务器为维度存储。
nonisolated struct Memory: Identifiable, Sendable {
    let id: UUID
    /// 关联的服务器 ID。
    var serverID: UUID
    var content: String
    var updatedAt: Date

    init(id: UUID = UUID(), serverID: UUID, content: String, updatedAt: Date = Date()) {
        self.id = id
        self.serverID = serverID
        self.content = content
        self.updatedAt = updatedAt
    }
}
