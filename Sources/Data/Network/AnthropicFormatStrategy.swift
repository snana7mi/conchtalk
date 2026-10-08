/// AnthropicFormatStrategy：Anthropic Messages API 的线上格式实现。
/// 接收 OpenAI 格式的 messages，自动转换为 Anthropic 格式后发送。
import Foundation

nonisolated struct AnthropicFormatStrategy: APIFormatStrategy {

    /// 是否在流式请求顶层加 `cache_control`（Anthropic 自动提示缓存：断点自动落在最后一个可缓存块，
    /// 随对话增长前移）。第三方 Anthropic 兼容端点 / 旧版 Bedrock 集成可能不认该字段（返回 400），
    /// 因此由调用方按端点决定，见 `supportsAutomaticPromptCaching(endpointURL:)`。
    let automaticPromptCaching: Bool

    init(automaticPromptCaching: Bool = false) {
        self.automaticPromptCaching = automaticPromptCaching
    }

    /// 仅官方 Claude API（api.anthropic.com）启用顶层 cache_control。
    static func supportsAutomaticPromptCaching(endpointURL: String) -> Bool {
        guard let host = URL(string: endpointURL.trimmingCharacters(in: .whitespacesAndNewlines))?.host else {
            return false
        }
        return host.lowercased() == "api.anthropic.com"
    }

    /// 请求体序列化：`.sortedKeys` 保证字典键顺序稳定（Swift 字典遍历顺序每次进程启动都会随机化，
    /// 键序变化会改变请求前缀，导致提示缓存失效）。
    static func serialize(_ body: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    // MARK: - Headers

    func setAuthHeaders(on request: inout URLRequest, apiKey: String) {
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
    }

    // MARK: - Request Body

    func buildStreamingRequestBody(
        messages: [[String: Any]],
        model: String,
        toolDefinitions: [[String: Any]]
    ) throws -> Data {
        let (systemText, convertedMessages) = convertMessages(messages)
        let convertedTools = convertToolDefinitions(toolDefinitions)

        var body: [String: Any] = [
            "model": model,
            "messages": convertedMessages,
            "max_tokens": 8192,
            "stream": true,
        ]
        if !systemText.isEmpty { body["system"] = systemText }
        if !convertedTools.isEmpty { body["tools"] = convertedTools }
        if automaticPromptCaching { body["cache_control"] = ["type": "ephemeral"] }
        return try Self.serialize(body)
    }

    func buildNonStreamingRequestBody(
        messages: [[String: Any]],
        model: String,
        maxTokens: Int?,
        temperature: Double?,
        reasoningEffort: String?
    ) throws -> Data {
        let (systemText, convertedMessages) = convertMessages(messages)

        var body: [String: Any] = [
            "model": model,
            "messages": convertedMessages,
            "max_tokens": maxTokens ?? 4096,
        ]
        if !systemText.isEmpty { body["system"] = systemText }
        if let temperature { body["temperature"] = temperature }
        // Anthropic 使用 thinking.budget_tokens 控制推理，reasoningEffort 暂不映射
        return try Self.serialize(body)
    }

    // MARK: - Response Parsing

    func processSSEStream(
        bytes: URLSession.AsyncBytes,
        continuation: AsyncStream<StreamingDelta>.Continuation
    ) async {
        /// 按 index 追踪正在构建中的 tool_use 块
        var toolBlocks: [Int: (id: String, name: String, jsonAccumulator: String)] = [:]
        /// 按 index 追踪 content block 类型（"text" / "thinking" / "tool_use"）
        var blockTypes: [Int: String] = [:]
        var currentEvent: String?
        /// message_start 给出输入侧用量，message_delta 给出累计输出用量；在 message_delta 时合并产出
        var usage = StreamingTokenUsage()

        do {
            for try await line in bytes.lines {
                try Task.checkCancellation()

                // 解析 event: 行
                if line.hasPrefix("event: ") {
                    currentEvent = String(line.dropFirst(7))
                    continue
                }

                // 解析 data: 行
                guard line.hasPrefix("data: ") else { continue }
                let payload = String(line.dropFirst(6))

                guard let data = payload.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    continue
                }

                switch currentEvent {
                case "message_start":
                    if let message = json["message"] as? [String: Any],
                       let rawUsage = message["usage"] as? [String: Any] {
                        usage = Self.mergeUsage(usage, with: rawUsage)
                    }

                case "ping":
                    break

                case "content_block_start":
                    guard let index = json["index"] as? Int,
                          let block = json["content_block"] as? [String: Any],
                          let blockType = block["type"] as? String else { continue }
                    blockTypes[index] = blockType
                    if blockType == "tool_use",
                       let id = block["id"] as? String,
                       let name = block["name"] as? String {
                        toolBlocks[index] = (id: id, name: name, jsonAccumulator: "")
                    }

                case "content_block_delta":
                    guard let index = json["index"] as? Int,
                          let delta = json["delta"] as? [String: Any],
                          let deltaType = delta["type"] as? String else { continue }

                    switch deltaType {
                    case "text_delta":
                        if let text = delta["text"] as? String, !text.isEmpty {
                            continuation.yield(.content(text))
                        }
                    case "thinking_delta":
                        if let thinking = delta["thinking"] as? String, !thinking.isEmpty {
                            continuation.yield(.reasoning(thinking))
                        }
                    case "input_json_delta":
                        if let partial = delta["partial_json"] as? String {
                            toolBlocks[index]?.jsonAccumulator += partial
                        }
                    default:
                        break
                    }

                case "content_block_stop":
                    guard let index = json["index"] as? Int else { continue }
                    // 如果是 tool_use 块，组装完整 ToolCall 并 yield
                    if blockTypes[index] == "tool_use",
                       let block = toolBlocks.removeValue(forKey: index) {
                        let argsData = block.jsonAccumulator.data(using: .utf8) ?? Data()
                        let explanation: String
                        if let args = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any],
                           let expl = args["explanation"] as? String {
                            explanation = expl
                        } else {
                            explanation = block.name
                        }
                        let toolCall = ToolCall(
                            id: block.id,
                            toolName: block.name,
                            argumentsJSON: argsData,
                            explanation: explanation
                        )
                        continuation.yield(.toolCall(toolCall))
                    }
                    blockTypes.removeValue(forKey: index)

                case "message_delta":
                    // stop_reason 目前无需处理；usage 为累计值，合并后产出
                    if let rawUsage = json["usage"] as? [String: Any] {
                        usage = Self.mergeUsage(usage, with: rawUsage)
                        if !usage.isEmpty { continuation.yield(.usage(usage)) }
                    }

                case "message_stop":
                    continuation.yield(.done)
                    continuation.finish()
                    return

                case "error":
                    let message: String
                    if let errorObj = json["error"] as? [String: Any],
                       let msg = errorObj["message"] as? String {
                        message = msg
                    } else {
                        message = "Unknown Anthropic stream error"
                    }
                    continuation.yield(.error(AIServiceError.apiError(statusCode: 0, message: message)))
                    continuation.finish()
                    return

                default:
                    break
                }

                currentEvent = nil
            }

            // 如果流正常结束但未收到 message_stop，仍然完成
            continuation.yield(.done)
            continuation.finish()
        } catch {
            continuation.yield(.error(error))
            continuation.finish()
        }
    }

    /// 合并 Anthropic usage 对象（message_start.message.usage / message_delta.usage）。
    /// 后到的非空字段覆盖先前值（message_delta 中的数值为累计值）。
    static func mergeUsage(_ current: StreamingTokenUsage, with raw: [String: Any]) -> StreamingTokenUsage {
        var merged = current
        if let v = raw["input_tokens"] as? Int { merged.inputTokens = v }
        if let v = raw["output_tokens"] as? Int { merged.outputTokens = v }
        if let v = raw["cache_read_input_tokens"] as? Int { merged.cacheReadInputTokens = v }
        if let v = raw["cache_creation_input_tokens"] as? Int { merged.cacheCreationInputTokens = v }
        return merged
    }

    func parseNonStreamingContent(from data: Data) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let first = content.first,
              let text = first["text"] as? String else {
            throw AIServiceError.invalidResponse
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func parseError(data: Data, statusCode: Int) -> AIServiceError {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let errorObj = json["error"] as? [String: Any],
           let message = errorObj["message"] as? String {
            return .apiError(statusCode: statusCode, message: message)
        }
        let raw = String(data: data, encoding: .utf8) ?? "Unknown error"
        return .apiError(statusCode: statusCode, message: raw)
    }

    // MARK: - Private Helpers

    /// 将 OpenAI 格式消息数组转换为 Anthropic 格式。
    /// 返回 (systemText, messages)，system 消息被提取到顶层。
    private func convertMessages(_ openAIMessages: [[String: Any]]) -> (String, [[String: Any]]) {
        var systemParts: [String] = []
        var intermediate: [[String: Any]] = []

        for msg in openAIMessages {
            guard let role = msg["role"] as? String else { continue }

            switch role {
            case "system":
                if let content = msg["content"] as? String {
                    systemParts.append(content)
                }

            case "assistant":
                var contentBlocks: [[String: Any]] = []

                // reasoning/thinking → thinking 内容块（DeepSeek/Anthropic 思考模式必需）
                if let reasoning = msg["reasoning_content"] as? String, !reasoning.isEmpty {
                    contentBlocks.append(["type": "thinking", "thinking": reasoning])
                }

                // 文本内容（排除 NSNull）
                if let text = msg["content"] as? String, !text.isEmpty {
                    contentBlocks.append(["type": "text", "text": text])
                }

                // 工具调用 → tool_use 内容块
                if let toolCalls = msg["tool_calls"] as? [[String: Any]] {
                    for tc in toolCalls {
                        guard let id = tc["id"] as? String,
                              let function = tc["function"] as? [String: Any],
                              let name = function["name"] as? String else { continue }
                        let argsString = function["arguments"] as? String ?? "{}"
                        let input: Any
                        if let argsData = argsString.data(using: .utf8),
                           let parsed = try? JSONSerialization.jsonObject(with: argsData) {
                            input = parsed
                        } else {
                            input = [String: Any]()
                        }
                        contentBlocks.append([
                            "type": "tool_use",
                            "id": id,
                            "name": name,
                            "input": input,
                        ])
                    }
                }

                if !contentBlocks.isEmpty {
                    intermediate.append(["role": "assistant", "content": contentBlocks])
                }

            case "tool":
                // OpenAI tool result → Anthropic user message with tool_result 块
                let toolCallId = msg["tool_call_id"] as? String ?? ""
                let content = msg["content"] as? String ?? ""
                let block: [String: Any] = [
                    "type": "tool_result",
                    "tool_use_id": toolCallId,
                    "content": content,
                ]
                intermediate.append(["role": "user", "content": [block]])

            case "user":
                if let text = msg["content"] as? String {
                    intermediate.append([
                        "role": "user",
                        "content": [["type": "text", "text": text]],
                    ])
                }

            default:
                break
            }
        }

        // 确保消息严格 user/assistant 交替：合并相邻同角色消息
        let merged = mergeConsecutiveRoles(intermediate)
        let systemText = systemParts.joined(separator: "\n\n")
        return (systemText, merged)
    }

    /// 合并相邻同角色消息，保证 Anthropic 要求的 user/assistant 严格交替。
    private func mergeConsecutiveRoles(_ messages: [[String: Any]]) -> [[String: Any]] {
        guard !messages.isEmpty else { return [] }
        var result: [[String: Any]] = []

        for msg in messages {
            guard let role = msg["role"] as? String,
                  let content = msg["content"] as? [[String: Any]] else { continue }

            if let last = result.last,
               let lastRole = last["role"] as? String,
               lastRole == role,
               let lastContent = last["content"] as? [[String: Any]] {
                // 合并到上一条消息
                result[result.count - 1]["content"] = lastContent + content
            } else {
                result.append(msg)
            }
        }

        return result
    }

    /// 将 OpenAI 格式的工具定义转换为 Anthropic 格式。
    /// OpenAI: {type: "function", function: {name, description, parameters}}
    /// Anthropic: {name, description, input_schema}
    private func convertToolDefinitions(_ openAITools: [[String: Any]]) -> [[String: Any]] {
        openAITools.compactMap { tool in
            guard let function = tool["function"] as? [String: Any],
                  let name = function["name"] as? String else { return nil }
            var anthropicTool: [String: Any] = ["name": name]
            if let description = function["description"] as? String {
                anthropicTool["description"] = description
            }
            if let parameters = function["parameters"] {
                anthropicTool["input_schema"] = parameters
            }
            return anthropicTool
        }
    }
}
