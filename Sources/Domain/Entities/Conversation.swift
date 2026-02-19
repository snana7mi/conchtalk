/// 文件说明：Conversation，定义聊天会话的领域实体模型。
import Foundation

/// Conversation：
/// 表示某台服务器上的一条对话会话，包含标题、消息列表与时间戳信息。
struct Conversation: Identifiable, Hashable, Sendable {
    let id: UUID
    var serverID: UUID
    var title: String
    var messages: [Message]
    var createdAt: Date
    var updatedAt: Date

    /// 初始化会话实体。
    /// - Parameters:
    ///   - id: 会话标识。
    ///   - serverID: 所属服务器标识。
    ///   - title: 会话标题。
    ///   - messages: 会话消息列表。
    ///   - createdAt: 创建时间。
    ///   - updatedAt: 更新时间。
    init(id: UUID = UUID(), serverID: UUID, title: String = "New Conversation", messages: [Message] = [], createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.serverID = serverID
        self.title = title
        self.messages = messages
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// 仅基于 `id` 参与哈希，确保同一会话在集合中具备稳定身份。
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    /// ==：比较两个会话实体是否表示同一条记录。
    static func == (lhs: Conversation, rhs: Conversation) -> Bool {
        lhs.id == rhs.id
    }
}
