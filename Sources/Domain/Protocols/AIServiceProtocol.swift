/// 文件说明：AIServiceProtocol，定义 AI 对话服务接口与响应模型。
import Foundation

/// AIResponse：表示一次 AI 调用的标准化结果。
enum AIResponse: Sendable {
    /// 最终文本回复，可附带推理链内容。
    case text(String, reasoning: String?)
    /// 模型请求调用工具，可附带推理链内容。
    case toolCall(ToolCall, reasoning: String?)
}

/// AIServiceProtocol：
/// 约束 AI 服务层能力，覆盖流式增量输出与上下文占用估算。
nonisolated protocol AIServiceProtocol: Sendable {
    /// 流式发送用户消息，持续输出增量事件。
    /// - Parameters:
    ///   - message: 用户输入文本。
    ///   - conversationHistory: 当前会话历史。
    ///   - serverContext: 服务器上下文信息。
    ///   - serverID: 服务器标识，用于隔离上下文缓存。
    ///   - permissionLevel: 当前生效的操作权限等级。
    /// - Returns: `StreamingDelta` 流，可能包含推理片段、正文片段、工具调用与错误事件。
    func sendMessageStreaming(_ message: String, conversationHistory: [Message], serverContext: String, serverID: UUID?, permissionLevel: PermissionLevel, serverName: String, serverCapabilities: ServerCapabilities) -> AsyncStream<StreamingDelta>

    /// 流式回填工具结果，持续输出后续增量事件。
    /// - Parameters:
    ///   - result: 工具输出文本。
    ///   - forToolCall: 对应的工具调用信息。
    ///   - conversationHistory: 当前会话历史。
    ///   - serverContext: 服务器上下文信息。
    ///   - serverID: 服务器标识，用于隔离上下文缓存。
    ///   - permissionLevel: 当前生效的操作权限等级。
    ///   - serverName: 服务器名称，用于 AI 身份标识。
    ///   - serverCapabilities: 服务器能力信息，用于过滤工具定义。
    /// - Returns: `StreamingDelta` 流。
    func sendToolResultStreaming(_ result: String, forToolCall: ToolCall, conversationHistory: [Message], serverContext: String, serverID: UUID?, permissionLevel: PermissionLevel, serverName: String, serverCapabilities: ServerCapabilities) -> AsyncStream<StreamingDelta>

    /// 从最近消息中提取三层记忆摘要（会话/服务器/全局）。
    /// - Parameters:
    ///   - recentMessages: 最近的对话消息。
    ///   - existingConversationMemory: 现有会话记忆（可能为空）。
    ///   - existingServerMemory: 现有服务器记忆（可能为空）。
    ///   - existingGlobalMemory: 现有全局记忆（可能为空）。
    /// - Returns: 三层记忆摘要结果。
    func generateMemorySummary(
        recentMessages: [Message],
        existingConversationMemory: String?,
        existingServerMemory: String?,
        existingGlobalMemory: String?
    ) async throws -> MemorySummaryResult

    /// 发送简单的非流式 AI 请求，返回文本回复。
    /// - Parameter prompt: 输入提示词。
    /// - Returns: AI 回复文本。
    /// - Throws: 网络或解析异常。
    func sendSimpleMessage(_ prompt: String) async throws -> String
}

// MARK: - 便捷重载（不含 serverID，默认 nil）

extension AIServiceProtocol {
    func sendMessageStreaming(_ message: String, conversationHistory: [Message], serverContext: String, serverID: UUID? = nil) -> AsyncStream<StreamingDelta> {
        sendMessageStreaming(message, conversationHistory: conversationHistory, serverContext: serverContext, serverID: serverID, permissionLevel: .standard, serverName: "AI Assistant", serverCapabilities: .unknown)
    }

    func sendToolResultStreaming(_ result: String, forToolCall: ToolCall, conversationHistory: [Message], serverContext: String, serverID: UUID? = nil) -> AsyncStream<StreamingDelta> {
        sendToolResultStreaming(result, forToolCall: forToolCall, conversationHistory: conversationHistory, serverContext: serverContext, serverID: serverID, permissionLevel: .standard, serverName: "AI Assistant", serverCapabilities: .unknown)
    }
}
