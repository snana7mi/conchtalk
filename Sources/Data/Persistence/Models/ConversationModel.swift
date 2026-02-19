/// 文件说明：ConversationModel，定义会话在 SwiftData 中的持久化结构。
import Foundation
import SwiftData

/// ConversationModel：
/// 会话持久化模型，负责承载会话元数据并关联消息集合。
@Model
final class ConversationModel {
    @Attribute(.unique) var id: UUID
    var serverID: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date

    @Relationship(deleteRule: .cascade)
    var messages: [MessageModel] = []

    var server: ServerModel?

    /// 初始化会话持久化模型。
    /// - Parameters:
    ///   - id: 会话标识。
    ///   - serverID: 所属服务器标识。
    ///   - title: 会话标题。
    ///   - createdAt: 创建时间。
    ///   - updatedAt: 更新时间。
    init(id: UUID = UUID(), serverID: UUID, title: String = "New Conversation", createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.serverID = serverID
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// 转换为领域层 `Conversation` 实体。
    /// - Returns: 消息已按时间升序排列的领域会话对象。
    func toDomain() -> Conversation {
        let domainMessages = messages
            .sorted { $0.timestamp < $1.timestamp }
            .map { $0.toDomain() }
        return Conversation(id: id, serverID: serverID, title: title, messages: domainMessages, createdAt: createdAt, updatedAt: updatedAt)
    }
}
