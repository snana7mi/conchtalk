/// 文件说明：ToolCall，定义模型函数调用请求的领域实体模型。
import Foundation

/// ToolCall：
/// 表示模型请求执行某个工具时的结构化数据，
/// 可挂载在消息中并持久化到本地存储。
/// 新增字段均为可选且带默认值，旧版持久化的 toolCallJSON 仍可正常解码。
nonisolated struct ToolCall: Codable, Sendable {
    let id: String              // OpenAI tool_call ID (e.g. "call_abc123")
    let toolName: String        // "execute_ssh_command", "read_file", etc.
    let argumentsJSON: Data     // Raw JSON arguments, each tool decodes its own
    let explanation: String     // Human-readable explanation from AI

    /// 产生该调用的模型响应 ID（Anthropic `message.id`）。
    /// 同一响应中的多个工具调用共享此 ID，回放历史时据此合并回同一条 assistant 消息。
    var responseID: String? = nil

    /// 该响应中的 thinking / redacted_thinking 块（含 signature，原样保存）。
    /// 仅挂在同一响应的第一个工具调用上；回传工具结果时必须原样带回（Anthropic 要求）。
    var thinkingBlocks: [ThinkingBlock]? = nil

    /// 模型输出因达到 max_tokens 上限被截断，导致参数 JSON 不完整。
    /// 为 true 时不应执行，而是把截断原因作为工具结果反馈给模型。
    var truncatedByMaxTokens: Bool? = nil

    /// 是否因输出上限被截断。
    var isTruncated: Bool { truncatedByMaxTokens == true }

    /// 将原始参数 JSON 解码为字典，供工具分发层使用。
    /// - Returns: 参数字典。
    /// - Throws: 当 JSON 非对象结构或解码失败时抛出 `ToolError.invalidArguments`。
    func decodedArguments() throws -> [String: Any] {
        guard let dict = try JSONSerialization.jsonObject(with: argumentsJSON) as? [String: Any] else {
            throw ToolError.invalidArguments("Failed to decode arguments as JSON object")
        }
        return dict
    }

    /// 参数是否为合法 JSON 对象（空参数视为合法的空对象）。
    var hasValidArgumentsJSON: Bool {
        if argumentsJSON.isEmpty { return true }
        return (try? JSONSerialization.jsonObject(with: argumentsJSON)) as? [String: Any] != nil
    }
}

/// ThinkingBlock：
/// Anthropic 响应中的思考块，按原样保存以便在工具循环中回放。
/// - `thinking`：`thinking` 文本（模型可能以 `display: "omitted"` 返回空串）+ `signature`。
/// - `redacted_thinking`：加密的 `data`，客户端不可解读，但必须原样回传。
nonisolated struct ThinkingBlock: Codable, Sendable, Equatable {
    var type: String
    var thinking: String?
    var signature: String?
    var data: String?

    static func thinking(_ text: String, signature: String?) -> ThinkingBlock {
        ThinkingBlock(type: "thinking", thinking: text, signature: signature, data: nil)
    }

    static func redacted(data: String) -> ThinkingBlock {
        ThinkingBlock(type: "redacted_thinking", thinking: nil, signature: nil, data: data)
    }

    /// 转为 Anthropic Messages API 的 content block 字典。
    var anthropicContentBlock: [String: Any] {
        var block: [String: Any] = ["type": type]
        if type == "redacted_thinking" {
            block["data"] = data ?? ""
        } else {
            block["thinking"] = thinking ?? ""
            if let signature { block["signature"] = signature }
        }
        return block
    }

    /// 从 Anthropic content block 字典解析（未知类型返回 nil）。
    init?(anthropicContentBlock block: [String: Any]) {
        guard let type = block["type"] as? String else { return nil }
        switch type {
        case "thinking":
            self.init(type: type, thinking: block["thinking"] as? String ?? "", signature: block["signature"] as? String, data: nil)
        case "redacted_thinking":
            guard let data = block["data"] as? String else { return nil }
            self.init(type: type, thinking: nil, signature: nil, data: data)
        default:
            return nil
        }
    }

    init(type: String, thinking: String?, signature: String?, data: String?) {
        self.type = type
        self.thinking = thinking
        self.signature = signature
        self.data = data
    }
}
