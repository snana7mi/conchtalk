/// 文件说明：Message，定义聊天消息的领域实体模型。
import Foundation

/// Message：
/// 表示会话中的单条消息，覆盖用户输入、助手回复、工具执行结果与系统提示。
nonisolated struct Message: Identifiable, Sendable {
    let id: UUID
    var role: MessageRole
    var content: String
    var timestamp: Date
    var toolCall: ToolCall?     // Non-nil for tool-call messages
    var toolOutput: String?     // Raw output from tool execution
    var reasoningContent: String? // AI reasoning/thinking chain (e.g. DeepSeek R1)
    var isLoading: Bool

    /// MessageRole：定义消息在会话中的角色语义。
    enum MessageRole: String, Codable, Sendable {
        case user
        case assistant
        case command       // Kept as "command" for backward compat with persisted roleRaw
        case system
    }

    /// 初始化消息实体。
    /// - Parameters:
    ///   - id: 消息标识。
    ///   - role: 消息角色。
    ///   - content: 消息正文。
    ///   - timestamp: 消息时间戳。
    ///   - toolCall: 关联的工具调用信息（仅 command 消息使用）。
    ///   - toolOutput: 工具输出文本（仅 command 消息使用）。
    ///   - reasoningContent: 模型推理链内容（可选）。
    ///   - isLoading: 是否为占位加载消息。
    init(id: UUID = UUID(), role: MessageRole, content: String, timestamp: Date = Date(), toolCall: ToolCall? = nil, toolOutput: String? = nil, reasoningContent: String? = nil, isLoading: Bool = false) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.toolCall = toolCall
        self.toolOutput = toolOutput
        self.reasoningContent = reasoningContent
        self.isLoading = isLoading
    }
}
