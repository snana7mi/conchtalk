/// 文件说明：MemoryModel，定义记忆在 SwiftData 中的持久化结构。
import Foundation
import SwiftData

/// MemoryModel：
/// 记忆持久化模型，以 serverID 为唯一键，存储服务器级别的对话记忆文本。
@Model
final class MemoryModel {
    /// 唯一键：serverID，一个服务器对应一条记忆记录（upsert 语义）。
    @Attribute(.unique) var serverID: UUID
    var id: UUID
    var content: String
    var updatedAt: Date

    // MARK: - 同步字段
    var syncVersion: Int64 = 0
    var modifiedAt: Date = Date()
    var isDeleted: Bool = false
    var isRemoteMerge: Bool = false

    init(id: UUID = UUID(), serverID: UUID, content: String, updatedAt: Date = Date()) {
        self.id = id
        self.serverID = serverID
        self.content = content
        self.updatedAt = updatedAt
    }

    /// 转换为领域层 `Memory` 实体。
    func toDomain() -> Memory {
        Memory(id: id, serverID: serverID, content: content, updatedAt: updatedAt)
    }

    /// 从领域层 `Memory` 构建持久化模型。
    static func fromDomain(_ memory: Memory) -> MemoryModel {
        MemoryModel(
            id: memory.id,
            serverID: memory.serverID,
            content: memory.content,
            updatedAt: memory.updatedAt
        )
    }
}
