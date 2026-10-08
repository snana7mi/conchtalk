/// 文件说明：MessageBuilder，将应用内消息模型转换为 OpenAI 协议格式。
import Foundation

/// MessageBuilderOptions：控制消息构建行为的选项。
nonisolated struct MessageBuilderOptions: Sendable {
    /// assistant + tool_calls 历史消息是否附带 reasoning_content。
    var includeReasoningOnToolCallMessages: Bool = false
    /// 纯 assistant content 历史消息是否附带 reasoning_content。
    var includeReasoningOnPlainAssistantMessages: Bool = false
    /// 是否在 assistant + tool_calls 消息上附带原样保存的 Anthropic thinking 块（私有键，见
    /// `MessageBuilder.anthropicThinkingBlocksKey`）。自愈「移除思考」重试时关闭。
    var includeAnthropicThinkingBlocks: Bool = true
}

/// MessageBuilder：
/// 将应用内 [Message] 转为 OpenAI Chat Completions 协议的消息数组。
/// 纯函数，不持有状态。不含 system prompt — 由调用方在数组头部插入。
nonisolated enum MessageBuilder {

    /// 私有键：assistant 消息上原样保存的 Anthropic thinking 块数组（`[[String: Any]]`）。
    /// Anthropic 格式转换时展开为 content block；OpenAI 格式发送前会剔除所有 `_` 前缀键。
    static let anthropicThinkingBlocksKey = "_anthropic_thinking_blocks"

    /// 转换消息历史为 OpenAI 协议格式。
    static func build(from history: [Message], options: MessageBuilderOptions = MessageBuilderOptions()) -> [[String: Any]] {
        var result: [[String: Any]] = []

        // 计算每条消息的轮次距离，用于自动衰减旧 tool output
        let roundDistances = computeRoundDistances(for: history)
        // 模型可见的工具输出（轮次衰减 + 旧结果清理 + 头尾截断），与 token 估算共用同一规则
        let visibleOutputs = modelVisibleToolOutputs(for: history, roundDistances: roundDistances)

        // 已被合并进前一条 assistant 消息的工具调用消息
        var consumedIDs: Set<UUID> = []

        for (index, msg) in history.enumerated() where !msg.isLoading {
            // .error 类型的系统消息（如登录失败、token 过期）仅用于 UI 展示，不发给 AI，避免污染上下文
            if msg.role == .system && msg.systemMessageType == .error { continue }
            // contextBreak 仅作为上下文分割标记，不发送给 AI
            if msg.role == .system && msg.systemMessageType == .contextBreak { continue }

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
                    if consumedIDs.contains(msg.id) { continue }

                    // 同一模型响应中的多个工具调用（相同 responseID 且在历史中连续）合并回一条 assistant 消息，
                    // 与模型原始输出一致；Anthropic 回放 thinking 块时要求块与其 tool_use 位于同一条消息。
                    var group: [(Message, ToolCall)] = [(msg, toolCall)]
                    if let responseID = toolCall.responseID {
                        var next = index + 1
                        while next < history.count {
                            let candidate = history[next]
                            if candidate.isLoading { next += 1; continue }
                            guard candidate.role == .command,
                                  let candidateCall = candidate.toolCall,
                                  candidateCall.responseID == responseID else { break }
                            group.append((candidate, candidateCall))
                            consumedIDs.insert(candidate.id)
                            next += 1
                        }
                    }

                    // Assistant message with tool call(s)
                    var assistantToolCallMessage: [String: Any] = [
                        "role": "assistant",
                        "content": NSNull(),
                        "tool_calls": group.map { _, call in
                            [
                                "id": call.id,
                                "type": "function",
                                "function": [
                                    "name": call.toolName,
                                    "arguments": String(data: call.argumentsJSON, encoding: .utf8) ?? "{}",
                                ] as [String: Any],
                            ] as [String: Any]
                        },
                    ]
                    if options.includeReasoningOnToolCallMessages {
                        assistantToolCallMessage["reasoning_content"] = msg.reasoningContent ?? ""
                    }
                    if options.includeAnthropicThinkingBlocks,
                       let blocks = group.lazy.compactMap({ $0.1.thinkingBlocks }).first, !blocks.isEmpty {
                        assistantToolCallMessage[anthropicThinkingBlocksKey] = blocks.map(\.anthropicContentBlock)
                    }
                    result.append(assistantToolCallMessage)

                    for (groupMsg, call) in group {
                        result.append([
                            "role": "tool",
                            "tool_call_id": call.id,
                            "content": visibleOutputs[groupMsg.id] ?? groupMsg.toolOutput ?? "",
                        ])
                    }
                } else {
                    // UI-only command cards（如 subagent 结论卡）没有 tool_call_id，
                    // 不能按 OpenAI tool result 发送，但应作为普通上下文保留给后续轮次。
                    let summary = msg.toolOutput ?? msg.content
                    if !summary.isEmpty {
                        result.append([
                            "role": "user",
                            "content": "[Command result: \(msg.content)]\n\(summary)",
                        ])
                    }
                }
            case .system:
                // 系统消息发送给 AI 时使用英文，避免本地化文本影响 AI 的语言选择
                let englishContent = Self.englishSystemContent(for: msg)
                result.append(["role": "user", "content": "[System: \(englishContent)]"])
            }
        }

        return result
    }

    // MARK: - 工具结果

    /// 计算每条工具结果发给模型的内容（按消息 ID）。
    /// 规则（先命中先用）：
    /// 1. 失败输出且距今 > 3 轮：只保留第一行错误摘要；
    /// 2. 成功输出且距今 > 5 轮：只保留执行成功标记；
    /// 3. 不在最近 `keepRecentResults` 条内的大输出：清理为头尾预览存根（分批推进，缓存友好）；
    /// 4. 其余：超过上限时头尾截断。
    static func modelVisibleToolOutputs(for history: [Message]) -> [UUID: String] {
        modelVisibleToolOutputs(for: history, roundDistances: computeRoundDistances(for: history))
    }

    private static func modelVisibleToolOutputs(for history: [Message], roundDistances: [UUID: Int]) -> [UUID: String] {
        let results = history.filter { !$0.isLoading && $0.role == .command && $0.toolCall != nil }
        let cleared = ToolResultContextPolicy.clearedIndices(sizes: results.map { ($0.toolOutput ?? "").count })
        var outputs: [UUID: String] = [:]
        for (index, msg) in results.enumerated() {
            guard let toolCall = msg.toolCall else { continue }
            let toolContent = msg.toolOutput ?? ""
            let roundDistance = roundDistances[msg.id] ?? 0
            let isFailed = isFailedToolOutput(toolContent)
            if isFailed && roundDistance > 3 {
                let firstLine = toolContent.prefix(while: { $0 != "\n" })
                outputs[msg.id] = "[Tool: \(toolCall.toolName)] failed: \(firstLine)"
            } else if !isFailed && roundDistance > 5 {
                outputs[msg.id] = "[Tool: \(toolCall.toolName)] executed successfully (output omitted)"
            } else if cleared.contains(index) {
                outputs[msg.id] = ToolResultContextPolicy.clearedStub(toolName: toolCall.toolName, output: toolContent)
            } else {
                outputs[msg.id] = ToolResultContextPolicy.headTail(toolContent)
            }
        }
        return outputs
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
        case .error, .aiContext, .none:
            return msg.content
        }
    }
}
