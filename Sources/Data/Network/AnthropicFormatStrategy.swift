/// AnthropicFormatStrategy：Anthropic Messages API 的线上格式实现。
/// 接收 OpenAI 格式的 messages，自动转换为 Anthropic 格式后发送。
import Foundation

nonisolated struct AnthropicFormatStrategy: APIFormatStrategy {

    /// 是否在流式请求顶层加 `cache_control`（Anthropic 自动提示缓存：断点自动落在最后一个可缓存块，
    /// 随对话增长前移）。第三方 Anthropic 兼容端点 / 旧版 Bedrock 集成可能不认该字段（返回 400），
    /// 因此由调用方按端点决定，见 `supportsAutomaticPromptCaching(endpointURL:)`。
    let automaticPromptCaching: Bool

    /// 用户指定的 max_tokens；nil 表示按模型自动（见 `AnthropicModelCapabilities.defaultMaxOutputTokens`）。
    let maxOutputTokens: Int?

    /// 思考力度；`.modelDefault` 时不发送 `thinking` / `output_config`，沿用模型默认。
    let thinkingLevel: AIThinkingLevel

    /// 强制使用的思考模式（400 自愈后切换）；nil 表示按模型名推断。
    let thinkingModeOverride: AnthropicThinkingMode?

    init(
        automaticPromptCaching: Bool = false,
        maxOutputTokens: Int? = nil,
        thinkingLevel: AIThinkingLevel = .modelDefault,
        thinkingModeOverride: AnthropicThinkingMode? = nil
    ) {
        self.automaticPromptCaching = automaticPromptCaching
        self.maxOutputTokens = maxOutputTokens
        self.thinkingLevel = thinkingLevel
        self.thinkingModeOverride = thinkingModeOverride
    }

    /// 返回切换思考模式后的副本（用于 400 自愈重试）。
    func withThinkingMode(_ mode: AnthropicThinkingMode) -> AnthropicFormatStrategy {
        AnthropicFormatStrategy(
            automaticPromptCaching: automaticPromptCaching,
            maxOutputTokens: maxOutputTokens,
            thinkingLevel: thinkingLevel,
            thinkingModeOverride: mode
        )
    }

    /// 本次请求实际使用的 max_tokens。
    func resolvedMaxTokens(model: String) -> Int {
        maxOutputTokens ?? AnthropicModelCapabilities.defaultMaxOutputTokens(for: model)
    }

    /// 本次请求实际使用的思考模式。
    func resolvedThinkingMode(model: String) -> AnthropicThinkingMode {
        thinkingModeOverride ?? AnthropicModelCapabilities.thinkingMode(for: model)
    }

    /// 按思考力度向请求体写入 `thinking` / `output_config`。
    /// - adaptive：`thinking: {type: "adaptive"}` + `output_config: {effort}`
    /// - manual：`thinking: {type: "enabled", budget_tokens}`（预算 ≥1024 且 < max_tokens）
    func applyThinking(to body: inout [String: Any], model: String, maxTokens: Int) {
        guard let effort = thinkingLevel.effortValue else { return }
        switch resolvedThinkingMode(model: model) {
        case .adaptive:
            body["thinking"] = ["type": "adaptive"]
            body["output_config"] = ["effort": effort]
        case .manual:
            if let budget = AnthropicModelCapabilities.manualThinkingBudget(level: thinkingLevel, maxTokens: maxTokens) {
                body["thinking"] = ["type": "enabled", "budget_tokens": budget]
            }
        }
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

        let maxTokens = resolvedMaxTokens(model: model)
        var body: [String: Any] = [
            "model": model,
            "messages": convertedMessages,
            "max_tokens": maxTokens,
            "stream": true,
        ]
        if !systemText.isEmpty { body["system"] = systemText }
        if !convertedTools.isEmpty { body["tools"] = convertedTools }
        applyThinking(to: &body, model: model, maxTokens: maxTokens)
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
        // Opus 4.7+ / 5.x 等模型对任何非默认 temperature 一律返回 400，标题 / 记忆等辅助请求直接省略
        if let temperature, !AnthropicModelCapabilities.rejectsSamplingParameters(model) {
            body["temperature"] = temperature
        }
        // 辅助请求要求低推理（"none"/"low"）：在支持 effort 的模型上降到 low，
        // 避免默认开启思考的 5.x 模型把很小的 max_tokens 全耗在思考上而没有正文
        if let reasoningEffort, reasoningEffort == "none" || reasoningEffort == "low",
           AnthropicModelCapabilities.supportsEffort(model) {
            body["output_config"] = ["effort": "low"]
        }
        return try Self.serialize(body)
    }

    // MARK: - Response Parsing

    func processSSEStream(
        bytes: URLSession.AsyncBytes,
        continuation: AsyncStream<StreamingDelta>.Continuation
    ) async {
        // max_tokens 仅用于截断提示文案；模型名在此不可得，提示中省略具体自动值
        var parser = AnthropicStreamParser(maxTokens: maxOutputTokens)
        var currentEvent: String?

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

                // 部分兼容端点不发 event: 行，退回 data 中的 type 字段
                let event = currentEvent ?? (json["type"] as? String)
                for delta in parser.handle(event: event, json: json) {
                    continuation.yield(delta)
                }
                currentEvent = nil
                if parser.isFinished {
                    continuation.finish()
                    return
                }
            }

            // 流正常结束但未收到 message_stop：仍产出缓冲内容并完成
            for delta in parser.finish() {
                continuation.yield(delta)
            }
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
              let content = json["content"] as? [[String: Any]] else {
            throw AIServiceError.invalidResponse
        }
        // 开启思考的模型首块是 thinking，需拼接所有 text 块而不是只取第一块
        let texts = content.compactMap { block -> String? in
            guard (block["type"] as? String ?? "text") == "text" else { return nil }
            return block["text"] as? String
        }
        guard !texts.isEmpty else { throw AIServiceError.invalidResponse }
        return texts.joined().trimmingCharacters(in: .whitespacesAndNewlines)
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

                // 优先原样回放 Anthropic 返回的 thinking / redacted_thinking 块（含 signature）；
                // 否则退回 reasoning_content（DeepSeek 等兼容端点的思考模式需要）
                if let verbatim = msg[MessageBuilder.anthropicThinkingBlocksKey] as? [[String: Any]], !verbatim.isEmpty {
                    contentBlocks.append(contentsOf: verbatim)
                } else if let reasoning = msg["reasoning_content"] as? String, !reasoning.isEmpty {
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
