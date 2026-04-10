/// 文件说明：ChatMessageRepository，聚焦消息持久化的仓储层，封装 SwiftDataStore 消息操作。
import Foundation

/// ChatMessageRepository：
/// 提供聊天消息的窄接口持久化边界，封装 SwiftDataStore 的消息读写方法。
/// 不包含 UI 状态，仅负责消息的追加、加载、批量写入等持久化操作。
struct ChatMessageRepository: Sendable {
    /// 底层持久化存储。
    private let store: SwiftDataStore

    init(store: SwiftDataStore) {
        self.store = store
    }

    // MARK: - 单条追加

    /// 追加单条消息到指定服务器。幂等：同 ID 消息已存在时静默跳过。
    func appendMessage(_ message: Message, toServer serverID: UUID) async throws {
        try await store.addMessage(message, toServer: serverID)
    }

    // MARK: - 批量追加

    /// 批量追加消息到指定服务器。幂等：已存在的消息自动去重。
    func appendMessages(_ messages: [Message], toServer serverID: UUID) async throws {
        try await store.addMessages(messages, toServer: serverID)
    }

    // MARK: - 系统消息

    /// 追加系统消息（如连接/断开/错误等提示）。
    func appendSystemMessage(
        _ content: String,
        type: Message.SystemMessageType,
        toServer serverID: UUID
    ) async throws {
        let message = Message(
            role: .system,
            content: content,
            systemMessageType: type
        )
        try await store.addMessage(message, toServer: serverID)
    }

    // MARK: - AI 上下文消息

    /// 追加 AI 专用上下文消息（发送给 AI 但不在聊天界面显示）。
    func appendAIContextMessage(
        _ content: String,
        toServer serverID: UUID
    ) async throws {
        let message = Message(
            role: .system,
            content: content,
            systemMessageType: .aiContext
        )
        try await store.addMessage(message, toServer: serverID)
    }

    // MARK: - 上下文断点

    /// 追加上下文断点标记，用于分割上下文窗口。
    func appendContextBreak(toServer serverID: UUID) async throws {
        let message = Message(
            role: .system,
            content: "",
            systemMessageType: .contextBreak
        )
        try await store.addMessage(message, toServer: serverID)
    }

    // MARK: - 加载

    /// 重新加载指定服务器的所有消息，按时间戳升序排列。
    func reloadMessages(forServer serverID: UUID) async throws -> [Message] {
        try await store.fetchMessages(forServer: serverID)
    }

    /// 重新加载指定服务器的消息，限制返回条数。
    func reloadMessages(forServer serverID: UUID, limit: Int) async throws -> [Message] {
        try await store.fetchMessages(forServer: serverID, limit: limit)
    }

    /// 获取最近 N 条消息（用于初始加载）。
    func reloadRecentMessages(forServer serverID: UUID, limit: Int) async throws -> [Message] {
        try await store.fetchRecentMessages(forServer: serverID, limit: limit)
    }

    /// 获取指定游标之前的消息（用于向上翻页）。
    func reloadOlderMessages(
        forServer serverID: UUID,
        limit: Int,
        beforeTimestamp: Date,
        beforeID: UUID
    ) async throws -> [Message] {
        try await store.fetchOlderMessages(
            forServer: serverID,
            limit: limit,
            beforeTimestamp: beforeTimestamp,
            beforeID: beforeID
        )
    }
}
