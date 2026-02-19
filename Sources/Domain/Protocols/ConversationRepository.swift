/// 文件说明：ConversationRepository，定义会话与消息持久化访问契约。
import Foundation

/// ConversationRepository：
/// 抽象会话仓储能力，统一会话保存、查询、删除与消息追加行为。
protocol ConversationRepository: Sendable {
    /// 保存（创建或更新）会话。
    /// - Parameter conversation: 待保存的会话实体。
    /// - Throws: 持久化失败时抛出。
    func save(_ conversation: Conversation) async throws

    /// 查询指定服务器下的会话列表。
    /// - Parameter serverID: 服务器标识。
    /// - Returns: 对应服务器下的会话集合。
    /// - Throws: 查询失败时抛出。
    func fetch(forServer serverID: UUID) async throws -> [Conversation]

    /// 查询全部会话。
    /// - Returns: 所有会话集合。
    /// - Throws: 查询失败时抛出。
    func fetchAll() async throws -> [Conversation]

    /// 删除会话。
    /// - Parameter conversationID: 会话标识。
    /// - Throws: 删除失败时抛出。
    func delete(_ conversationID: UUID) async throws

    /// 向会话追加一条消息。
    /// - Parameters:
    ///   - message: 待追加消息。
    ///   - conversationID: 目标会话标识。
    /// - Throws: 会话不存在或写入失败时抛出。
    func addMessage(_ message: Message, to conversationID: UUID) async throws
}
