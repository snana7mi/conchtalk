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
    /// 上下文正在压缩中（旧消息折叠为摘要）。
    case contextCompressing
    /// 本次请求的 token 用量（含提示缓存读写），仅在服务端返回 usage 时产出。
    case usage(StreamingTokenUsage)
    /// 流中断或处理失败。
    case error(Error)
}

/// StreamingTokenUsage：流式请求的 token 用量。
/// 字段均为可选：不同服务商返回的字段不同，缺失即为 nil。
nonisolated struct StreamingTokenUsage: Sendable, Equatable {
    /// 未命中缓存的输入 token（Anthropic `input_tokens`；OpenAI 为 `prompt_tokens`，含缓存部分）。
    var inputTokens: Int?
    /// 输出 token。
    var outputTokens: Int?
    /// 从提示缓存读取的输入 token（Anthropic `cache_read_input_tokens`；OpenAI `prompt_tokens_details.cached_tokens`）。
    var cacheReadInputTokens: Int?
    /// 写入提示缓存的输入 token（仅 Anthropic `cache_creation_input_tokens`）。
    var cacheCreationInputTokens: Int?

    init(
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        cacheReadInputTokens: Int? = nil,
        cacheCreationInputTokens: Int? = nil
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadInputTokens = cacheReadInputTokens
        self.cacheCreationInputTokens = cacheCreationInputTokens
    }

    /// 是否没有任何字段。
    var isEmpty: Bool {
        inputTokens == nil && outputTokens == nil && cacheReadInputTokens == nil && cacheCreationInputTokens == nil
    }
}
