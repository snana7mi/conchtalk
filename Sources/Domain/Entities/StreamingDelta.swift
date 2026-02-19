/// 文件说明：StreamingDelta，定义 AI 流式响应过程中的增量事件模型。
import Foundation

/// StreamingDelta：
/// 表示流式响应中的单个事件，可用于驱动 UI 实时更新与流程收敛。
enum StreamingDelta: Sendable {
    /// 推理链文本增量。
    case reasoning(String)
    /// 最终回复正文增量。
    case content(String)
    /// 组装完成的工具调用请求。
    case toolCall(ToolCall)
    /// 流正常结束。
    case done
    /// 流中断或处理失败。
    case error(Error)
}
