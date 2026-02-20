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
protocol AIServiceProtocol: Sendable {
    /// 流式发送用户消息，持续输出增量事件。
    /// - Parameters:
    ///   - message: 用户输入文本。
    ///   - conversationHistory: 当前会话历史。
    ///   - serverContext: 服务器上下文信息。
    /// - Returns: `StreamingDelta` 流，可能包含推理片段、正文片段、工具调用与错误事件。
    func sendMessageStreaming(_ message: String, conversationHistory: [Message], serverContext: String) -> AsyncStream<StreamingDelta>

    /// 流式回填工具结果，持续输出后续增量事件。
    /// - Parameters:
    ///   - result: 工具输出文本。
    ///   - forToolCall: 对应的工具调用信息。
    ///   - conversationHistory: 当前会话历史。
    ///   - serverContext: 服务器上下文信息。
    /// - Returns: `StreamingDelta` 流。
    func sendToolResultStreaming(_ result: String, forToolCall: ToolCall, conversationHistory: [Message], serverContext: String) -> AsyncStream<StreamingDelta>

    /// 估算当前会话占用模型上下文窗口的比例。
    /// - Parameters:
    ///   - history: 会话历史消息。
    ///   - serverContext: 服务器上下文信息。
    /// - Returns: 占用比例（`0...1`）。
    func estimateContextUsage(history: [Message], serverContext: String) -> Double

    /// 根据对话内容生成简短的会话标题。
    /// - Parameter messages: 会话消息（取前几条即可）。
    /// - Returns: AI 生成的简短标题字符串。
    /// - Throws: 网络或解析异常。
    func generateTitle(for messages: [Message]) async throws -> String
}
