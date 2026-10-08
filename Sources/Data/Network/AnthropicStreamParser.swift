/// 文件说明：AnthropicStreamParser，Anthropic Messages SSE 事件的纯状态机解析器。
import Foundation

/// AnthropicStreamParser：
/// 把逐条 SSE 事件（event 名 + data JSON）转换为 `StreamingDelta`。
/// - 原样收集 thinking（含 `signature_delta`）与 `redacted_thinking` 块，挂到本次响应的第一个工具调用上，
///   供下一轮回传工具结果时逐字节回放（Anthropic 要求，否则 400）。
/// - 工具调用缓冲到 `message_stop` 再统一产出，以便结合 `stop_reason` 判断是否被 max_tokens 截断。
/// - 被截断的工具调用标记 `truncatedByMaxTokens`，由执行层反馈给模型而不是报 JSON 解码错误。
/// 纯值类型、无 I/O，便于单元测试。
nonisolated struct AnthropicStreamParser {

    /// 本次请求的 max_tokens，用于生成截断提示。
    let maxTokens: Int?

    private var messageID: String?
    private var blockTypes: [Int: String] = [:]
    private var toolBlocks: [Int: (id: String, name: String, json: String)] = [:]
    private var openThinking: [Int: ThinkingBlock] = [:]
    private var thinkingBlocks: [ThinkingBlock] = []
    private var toolCalls: [ToolCall] = []
    private var producedText = false
    private(set) var stopReason: String?
    private var usage = StreamingTokenUsage()
    private(set) var isFinished = false

    init(maxTokens: Int? = nil) {
        self.maxTokens = maxTokens
    }

    /// 处理一条 SSE 事件，返回需要立即产出的 delta。
    mutating func handle(event: String?, json: [String: Any]) -> [StreamingDelta] {
        guard !isFinished else { return [] }
        switch event {
        case "message_start":
            if let message = json["message"] as? [String: Any] {
                messageID = message["id"] as? String
                if let rawUsage = message["usage"] as? [String: Any] {
                    usage = AnthropicFormatStrategy.mergeUsage(usage, with: rawUsage)
                }
            }
            return []

        case "content_block_start":
            guard let index = json["index"] as? Int,
                  let block = json["content_block"] as? [String: Any],
                  let blockType = block["type"] as? String else { return [] }
            blockTypes[index] = blockType
            switch blockType {
            case "tool_use":
                if let id = block["id"] as? String, let name = block["name"] as? String {
                    toolBlocks[index] = (id: id, name: name, json: "")
                }
            case "thinking":
                openThinking[index] = .thinking(block["thinking"] as? String ?? "", signature: block["signature"] as? String)
            case "redacted_thinking":
                openThinking[index] = .redacted(data: block["data"] as? String ?? "")
            default:
                break
            }
            return []

        case "content_block_delta":
            guard let index = json["index"] as? Int,
                  let delta = json["delta"] as? [String: Any],
                  let deltaType = delta["type"] as? String else { return [] }
            switch deltaType {
            case "text_delta":
                if let text = delta["text"] as? String, !text.isEmpty {
                    producedText = true
                    return [.content(text)]
                }
            case "thinking_delta":
                if let thinking = delta["thinking"] as? String, !thinking.isEmpty {
                    if var block = openThinking[index] {
                        block.thinking = (block.thinking ?? "") + thinking
                        openThinking[index] = block
                    }
                    return [.reasoning(thinking)]
                }
            case "signature_delta":
                if let signature = delta["signature"] as? String {
                    if var block = openThinking[index] {
                        block.signature = (block.signature ?? "") + signature
                        openThinking[index] = block
                    }
                }
            case "input_json_delta":
                if let partial = delta["partial_json"] as? String {
                    toolBlocks[index]?.json += partial
                }
            default:
                break
            }
            return []

        case "content_block_stop":
            guard let index = json["index"] as? Int else { return [] }
            if let block = openThinking.removeValue(forKey: index) {
                thinkingBlocks.append(block)
            }
            if blockTypes[index] == "tool_use", let block = toolBlocks.removeValue(forKey: index) {
                toolCalls.append(Self.makeToolCall(id: block.id, name: block.name, json: block.json))
            }
            blockTypes.removeValue(forKey: index)
            return []

        case "message_delta":
            if let delta = json["delta"] as? [String: Any], let reason = delta["stop_reason"] as? String {
                stopReason = reason
            }
            if let rawUsage = json["usage"] as? [String: Any] {
                usage = AnthropicFormatStrategy.mergeUsage(usage, with: rawUsage)
                if !usage.isEmpty { return [.usage(usage)] }
            }
            return []

        case "message_stop":
            return finish()

        case "error":
            isFinished = true
            let message: String
            if let errorObj = json["error"] as? [String: Any], let msg = errorObj["message"] as? String {
                message = msg
            } else {
                message = "Unknown Anthropic stream error"
            }
            return [.error(AIServiceError.apiError(statusCode: 0, message: message))]

        default:
            return []
        }
    }

    /// 结束解析（`message_stop` 或流意外结束时调用），产出缓冲的工具调用、截断提示与 `.done`。
    mutating func finish() -> [StreamingDelta] {
        guard !isFinished else { return [] }
        isFinished = true

        // 未收到 content_block_stop 的残留块（流被截断）也按截断处理
        for index in toolBlocks.keys.sorted() {
            if let block = toolBlocks[index] {
                toolCalls.append(Self.makeToolCall(id: block.id, name: block.name, json: block.json))
            }
        }
        toolBlocks.removeAll()
        for index in openThinking.keys.sorted() {
            if let block = openThinking[index] { thinkingBlocks.append(block) }
        }
        openThinking.removeAll()

        let hitOutputLimit = stopReason == "max_tokens" || stopReason == "model_context_window_exceeded"
        var deltas: [StreamingDelta] = []
        for (offset, var call) in toolCalls.enumerated() {
            call.responseID = messageID
            if offset == 0, !thinkingBlocks.isEmpty {
                call.thinkingBlocks = thinkingBlocks
            }
            // 参数不完整：被截断（max_tokens）或流中断导致 JSON 不合法
            if !call.hasValidArgumentsJSON && (hitOutputLimit || stopReason == nil) {
                call.truncatedByMaxTokens = true
            }
            deltas.append(.toolCall(call))
        }

        if toolCalls.isEmpty && hitOutputLimit {
            deltas.append(.content(Self.truncationNotice(maxTokens: maxTokens, hadText: producedText)))
        }
        deltas.append(.done)
        return deltas
    }

    /// 回复文本被截断时追加的提示（英文：会作为 assistant 文本回放给模型）。
    static func truncationNotice(maxTokens: Int?, hadText: Bool) -> String {
        let limit = maxTokens.map { " (\($0) tokens)" } ?? ""
        let prefix = hadText ? "\n\n" : ""
        return prefix + "[Reply cut off: the model reached its max output token limit\(limit). Send “continue” to let it finish, or raise Max Output Tokens in Settings.]"
    }

    private static func makeToolCall(id: String, name: String, json: String) -> ToolCall {
        // 无参数工具：Anthropic 可能不发送任何 input_json_delta，视为空对象
        let argsData = (json.isEmpty ? "{}" : json).data(using: .utf8) ?? Data()
        let explanation: String
        if let args = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any],
           let expl = args["explanation"] as? String {
            explanation = expl
        } else {
            explanation = name
        }
        return ToolCall(id: id, toolName: name, argumentsJSON: argsData, explanation: explanation)
    }
}
