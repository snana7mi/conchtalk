/// 文件说明：MessageBuilder，将应用内消息模型转换为 OpenAI 协议格式。
import Foundation

/// MessageBuilderOptions：控制消息构建行为的选项。
nonisolated struct MessageBuilderOptions: Sendable {
    /// assistant + tool_calls 历史消息是否附带 reasoning_content。
    var includeReasoningOnToolCallMessages: Bool = false
    /// 纯 assistant content 历史消息是否附带 reasoning_content。
    var includeReasoningOnPlainAssistantMessages: Bool = false
}

/// MessageBuilder：
/// 将应用内 [Message] 转为 OpenAI Chat Completions 协议的消息数组。
/// 纯函数，不持有状态。不含 system prompt — 由调用方在数组头部插入。
nonisolated enum MessageBuilder {

    /// 转换消息历史为 OpenAI 协议格式。
    static func build(from history: [Message], options: MessageBuilderOptions = MessageBuilderOptions()) -> [[String: Any]] {
        var result: [[String: Any]] = []

        // 计算每条消息的轮次距离，用于自动衰减旧 tool output
        let roundDistances = computeRoundDistances(for: history)

        for msg in history where !msg.isLoading {
            // .error 类型的系统消息（如登录失败、token 过期）仅用于 UI 展示，不发给 AI，避免污染上下文
            if msg.role == .system && msg.systemMessageType == .error { continue }
            // contextBreak 仅作为上下文分割标记，不发送给 AI
            if msg.role == .system && msg.systemMessageType == .contextBreak { continue }
            // relayStatus 为 relay 连接状态噪音，不发送给 AI
            if msg.role == .system && msg.systemMessageType == .relayStatus { continue }

            let roundDistance = roundDistances[msg.id] ?? 0

            // commandDenied 超过 2 轮后移除，减少上下文噪音
            if msg.role == .system && msg.systemMessageType == .commandDenied && roundDistance > 2 {
                continue
            }

            switch msg.role {
            case .user:
                result.append(["role": "user", "content": msg.content])
            case .assistant:
                var assistantMessage: [String: Any] = [
                    "role": "assistant",
                    "content": msg.content,
                ]
                if options.includeReasoningOnPlainAssistantMessages {
                    assistantMessage["reasoning_content"] = msg.reasoningContent ?? ""
                }
                result.append(assistantMessage)
            case .command:
                if let toolCall = msg.toolCall {
                    let argsString = String(data: toolCall.argumentsJSON, encoding: .utf8) ?? "{}"

                    // Assistant message with tool call
                    var assistantToolCallMessage: [String: Any] = [
                        "role": "assistant",
                        "content": NSNull(),
                        "tool_calls": [
                            [
                                "id": toolCall.id,
                                "type": "function",
                                "function": [
                                    "name": toolCall.toolName,
                                    "arguments": argsString,
                                ] as [String: Any],
                            ] as [String: Any],
                        ],
                    ]
                    if options.includeReasoningOnToolCallMessages {
                        assistantToolCallMessage["reasoning_content"] = msg.reasoningContent ?? ""
                    }
                    result.append(assistantToolCallMessage)

                    // Tool response — 根据轮次距离自动衰减旧输出
                    let toolContent = msg.toolOutput ?? ""
                    let decayedContent: String
                    let isFailed = isFailedToolOutput(toolContent)

                    if isFailed && roundDistance > 3 {
                        // 失败输出：保留第一行错误摘要
                        let firstLine = toolContent.prefix(while: { $0 != "\n" })
                        decayedContent = "[Tool: \(toolCall.toolName)] failed: \(firstLine)"
                    } else if !isFailed && roundDistance > 5 {
                        // 成功输出：仅保留执行成功标记
                        decayedContent = "[Tool: \(toolCall.toolName)] executed successfully (output omitted)"
                    } else {
                        // 未衰减：兜底截断，防止旧大输出撑爆上下文
                        let maxToolOutput = 32_000
                        decayedContent = toolContent.count > maxToolOutput
                            ? String(toolContent.prefix(maxToolOutput)) + "\n\n... [Output truncated]"
                            : toolContent
                    }

                    result.append([
                        "role": "tool",
                        "tool_call_id": toolCall.id,
                        "content": decayedContent,
                    ])
                }
            case .system:
                // 系统消息发送给 AI 时使用英文，避免本地化文本影响 AI 的语言选择
                let englishContent = Self.englishSystemContent(for: msg)
                result.append(["role": "user", "content": "[System: \(englishContent)]"])
            }
        }

        return result
    }

    // MARK: - 轮次距离计算

    /// 从尾部扫描消息列表，每遇到一条 user 消息时轮次计数器 +1，
    /// 将每条消息的 UUID 映射到其轮次距离。
    /// 轮次定义：1 轮 = 1 条 user 消息 + AI 的完整回复（含所有 tool calls）。
    private static func computeRoundDistances(for messages: [Message]) -> [UUID: Int] {
        var distances: [UUID: Int] = [:]
        var roundCounter = 0

        // 从末尾向头部扫描
        for msg in messages.reversed() {
            distances[msg.id] = roundCounter
            if msg.role == .user {
                roundCounter += 1
            }
        }

        return distances
    }

    // MARK: - 失败输出检测

    /// 检测 tool output 是否包含错误指标（大小写不敏感）。
    private static func isFailedToolOutput(_ output: String) -> Bool {
        let lowered = output.lowercased()
        let errorIndicators = [
            "error:",
            "failed:",
            "command not found",
            "no such file",
            "permission denied",
            "connection refused",
            "blocked:",
        ]
        return errorIndicators.contains { lowered.contains($0) }
    }

    /// 将系统消息转为英文描述，确保 AI 始终看到英文上下文。
    private static func englishSystemContent(for msg: Message) -> String {
        switch msg.systemMessageType {
        case .connected:
            return "SSH connection established"
        case .disconnected:
            return "SSH disconnected"
        case .connectionLost:
            return "Connection lost unexpectedly"
        case .reconnected:
            return "SSH connection restored"
        case .connectionFailed:
            return "Connection failed"
        case .info:
            return "Connected to server"
        case .commandDenied:
            return "Command denied by user"
        case .skillLoaded:
            return "Skill loaded"
        case .contextBreak:
            return ""
        case .relayStatus:
            return ""
        case .error, .aiContext, .none:
            return msg.content
        }
    }
}
