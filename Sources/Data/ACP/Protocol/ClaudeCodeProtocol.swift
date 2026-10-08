/// 文件说明：ClaudeCodeProtocol，Claude Code CLI stream-json 模式的消息类型定义。

import Foundation

// MARK: - 从 CLI stdout 接收的消息

/// ClaudeCodeMessage：Claude Code CLI 输出的 NDJSON 消息（按 type 字段区分）。
nonisolated enum ClaudeCodeMessage: Decodable, Sendable {
    case system(ClaudeSystemInit)
    case assistant(ClaudeAssistantMessage)
    case user(ClaudeUserToolResult)
    case result(ClaudeResult)
    case controlRequest(ClaudeControlRequest)
    case keepAlive

    private enum CodingKeys: String, CodingKey {
        case type
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "system":
            self = .system(try ClaudeSystemInit(from: decoder))
        case "assistant":
            self = .assistant(try ClaudeAssistantMessage(from: decoder))
        case "user":
            self = .user(try ClaudeUserToolResult(from: decoder))
        case "result":
            self = .result(try ClaudeResult(from: decoder))
        case "control_request":
            self = .controlRequest(try ClaudeControlRequest(from: decoder))
        case "keep_alive":
            self = .keepAlive
        default:
            // 未知类型静默忽略
            self = .keepAlive
        }
    }
}

/// ClaudeSystemInit：system.init 消息，首条消息，包含会话元数据。
nonisolated struct ClaudeSystemInit: Decodable, Sendable {
    let subtype: String?
    let sessionId: String
    let cwd: String?
    let tools: [String]?
    let model: String?
    let slashCommands: [String]?
    let agents: [String]?
    let claudeCodeVersion: String?

    private enum CodingKeys: String, CodingKey {
        case subtype
        case sessionId = "session_id"
        case cwd, tools, model
        case slashCommands = "slash_commands"
        case agents
        case claudeCodeVersion = "claude_code_version"
    }

    /// 是否为真正的 init 消息（区别于 hook_started、hook_response 等其他 system 子类型）。
    var isInit: Bool { subtype == "init" }
}

/// ClaudeAssistantMessage：assistant 消息，AI 的回复。
nonisolated struct ClaudeAssistantMessage: Decodable, Sendable {
    let sessionId: String?
    let message: ClaudeMessageBody

    private enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case message
    }
}

/// ClaudeMessageBody：assistant 消息体（对应 Anthropic BetaMessage 的子集）。
nonisolated struct ClaudeMessageBody: Decodable, Sendable {
    let role: String?
    let content: [ClaudeContentBlock]
    let usage: ClaudeUsage?
    let stopReason: String?

    private enum CodingKeys: String, CodingKey {
        case role, content, usage
        case stopReason = "stop_reason"
    }
}

/// ClaudeContentBlock：assistant 回复中的内容块。
nonisolated enum ClaudeContentBlock: Decodable, Sendable {
    case text(String)
    case thinking(String)
    case toolUse(id: String, name: String, input: [String: AnyCodableJSON])

    private enum CodingKeys: String, CodingKey {
        case type, text, thinking, id, name, input
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "text":
            let text = try container.decode(String.self, forKey: .text)
            self = .text(text)
        case "thinking":
            let thinking = try container.decode(String.self, forKey: .thinking)
            self = .thinking(thinking)
        case "tool_use":
            let id = try container.decode(String.self, forKey: .id)
            let name = try container.decode(String.self, forKey: .name)
            let input = (try? container.decode([String: AnyCodableJSON].self, forKey: .input)) ?? [:]
            self = .toolUse(id: id, name: name, input: input)
        default:
            // 未知 content block 类型，当作空文本
            self = .text("")
        }
    }
}

/// ClaudeUsage：token 用量。
nonisolated struct ClaudeUsage: Decodable, Sendable {
    let inputTokens: Int?
    let outputTokens: Int?
    let cacheReadInputTokens: Int?
    let cacheCreationInputTokens: Int?

    private enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cacheReadInputTokens = "cache_read_input_tokens"
        case cacheCreationInputTokens = "cache_creation_input_tokens"
    }
}

/// ClaudeUserToolResult：user 消息（CLI 自动填充的工具执行结果）。
nonisolated struct ClaudeUserToolResult: Decodable, Sendable {
    let sessionId: String?
    let message: ClaudeToolResultBody?

    private enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case message
    }
}

nonisolated struct ClaudeToolResultBody: Decodable, Sendable {
    let content: [ClaudeToolResultContent]?
}

nonisolated struct ClaudeToolResultContent: Decodable, Sendable {
    let type: String
    let toolUseId: String?
    let content: String?

    private enum CodingKeys: String, CodingKey {
        case type
        case toolUseId = "tool_use_id"
        case content
    }
}

/// ClaudeResult：result 消息，本轮完成。
nonisolated struct ClaudeResult: Decodable, Sendable {
    let subtype: String
    let sessionId: String?
    let result: String?
    let totalCostUsd: Double?
    let usage: ClaudeUsage?
    let isError: Bool?
    let errors: [String]?

    private enum CodingKeys: String, CodingKey {
        case subtype
        case sessionId = "session_id"
        case result
        case totalCostUsd = "total_cost_usd"
        case usage
        case isError = "is_error"
        case errors
    }
}

/// ClaudeControlRequest：权限请求。
nonisolated struct ClaudeControlRequest: Decodable, Sendable {
    let requestId: String
    let request: ClaudePermissionDetails

    private enum CodingKeys: String, CodingKey {
        case requestId = "request_id"
        case request
    }
}

nonisolated struct ClaudePermissionDetails: Decodable, Sendable {
    let subtype: String?
    let toolName: String?
    let input: [String: AnyCodableJSON]?
    let title: String?
    let description: String?

    private enum CodingKeys: String, CodingKey {
        case subtype
        case toolName = "tool_name"
        case input, title, description
    }
}

// MARK: - 写入 CLI stdin 的消息

/// ClaudeCodeUserMessage：发送给 Claude Code 的 prompt 消息。
nonisolated struct ClaudeCodeUserMessage: Encodable, Sendable {
    let type = "user"
    let sessionId: String
    let message: PromptContent
    let parentToolUseId: String?

    nonisolated struct PromptContent: Encodable, Sendable {
        let role = "user"
        let content: [ContentItem]

        nonisolated struct ContentItem: Encodable, Sendable {
            let type = "text"
            let text: String
        }
    }

    init(text: String, sessionId: String = "", parentToolUseId: String? = nil) {
        self.sessionId = sessionId
        self.parentToolUseId = parentToolUseId
        self.message = PromptContent(content: [.init(text: text)])
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case sessionId = "session_id"
        case message
        case parentToolUseId = "parent_tool_use_id"
    }
}

/// ClaudeCodeControlResponse：CLI 发来的 control_request 的回复。
/// 线格式与官方 claude-agent-sdk-python `_internal/query.py` 一致：
/// - 成功：`{"type":"control_response","response":{"subtype":"success","request_id":…,"response":{…}}}`
/// - 失败：`{"type":"control_response","response":{"subtype":"error","request_id":…,"error":"…"}}`
nonisolated struct ClaudeCodeControlResponse: Encodable, Sendable {
    let type = "control_response"
    let response: ResponsePayload

    nonisolated struct ResponsePayload: Encodable, Sendable {
        let subtype: String
        let requestId: String
        let response: BehaviorPayload?
        let error: String?

        private enum CodingKeys: String, CodingKey {
            case subtype
            case requestId = "request_id"
            case response
            case error
        }
    }

    /// can_use_tool 的决定。allow 时官方 SDK 总是回传 updatedInput（未修改则为原始 input）。
    nonisolated struct BehaviorPayload: Encodable, Sendable {
        let behavior: String
        let message: String?
        let updatedInput: [String: AnyCodableJSON]?

        init(behavior: String, message: String? = nil, updatedInput: [String: AnyCodableJSON]? = nil) {
            self.behavior = behavior
            self.message = message
            self.updatedInput = updatedInput
        }
    }

    static func allow(requestId: String, input: [String: AnyCodableJSON]? = nil) -> ClaudeCodeControlResponse {
        ClaudeCodeControlResponse(response: ResponsePayload(
            subtype: "success",
            requestId: requestId,
            response: BehaviorPayload(behavior: "allow", updatedInput: input ?? [:]),
            error: nil
        ))
    }

    static func deny(requestId: String, message: String) -> ClaudeCodeControlResponse {
        ClaudeCodeControlResponse(response: ResponsePayload(
            subtype: "success",
            requestId: requestId,
            response: BehaviorPayload(behavior: "deny", message: message),
            error: nil
        ))
    }

    /// 不支持的 control_request 子类型：回复 error，避免 CLI 一直等待。
    static func error(requestId: String, message: String) -> ClaudeCodeControlResponse {
        ClaudeCodeControlResponse(response: ResponsePayload(
            subtype: "error",
            requestId: requestId,
            response: nil,
            error: message
        ))
    }
}

/// ClaudeCodeControlRequestMessage：客户端发给 CLI 的 control_request（如中断当前轮）。
/// 与官方 SDK `Query.interrupt()` 一致：`{"type":"control_request","request_id":…,"request":{"subtype":"interrupt"}}`。
nonisolated struct ClaudeCodeControlRequestMessage: Encodable, Sendable {
    let type = "control_request"
    let requestId: String
    let request: Payload

    nonisolated struct Payload: Encodable, Sendable {
        let subtype: String
    }

    static func interrupt(requestId: String) -> ClaudeCodeControlRequestMessage {
        ClaudeCodeControlRequestMessage(requestId: requestId, request: Payload(subtype: "interrupt"))
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case requestId = "request_id"
        case request
    }
}
