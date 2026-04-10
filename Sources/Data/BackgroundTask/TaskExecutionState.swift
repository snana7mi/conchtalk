/// 文件说明：TaskExecutionEvent，任务执行过程中的事件定义。
import Foundation

// MARK: - TaskExecutionEvent

/// TaskExecutionEvent：
/// 任务执行过程中发出的事件，供上层观察者消费。
/// 与 TaskStreamingState 的区别：事件是一次性的通知，状态是可查询的快照。
enum TaskExecutionEvent: Sendable {
    /// 流式推理文本更新（累积全文）。
    case reasoningUpdate(String)
    /// 流式正文文本更新（累积全文）。
    case contentUpdate(String)
    /// 工具实时输出更新（累积全文）。
    case toolOutputUpdate(String)
    /// 代理流式事件批量推送。
    case agentStreamEvents([AgentStreamEvent])
    /// 上下文压缩状态变化。
    case contextCompressing(Bool)
    /// 中间消息已持久化。
    case intermediateMessage(Message)
    /// 工具调用需要用户审批。
    case toolCallNeedsConfirmation(ToolCall, deadline: Date)
    /// AI 建议连接编码代理。
    case agentConnectionSuggested(preferredAgent: String?, cwd: String?, directories: [String]?, homePath: String?)
    /// 任务完成（含结果消息列表）。
    case completed(serverID: UUID, resultMessages: [Message])
    /// 任务因取消结束（可能有部分消息）。
    case cancelled(serverID: UUID)
    /// 任务因错误结束。
    case failed(serverID: UUID, error: Error)
}
