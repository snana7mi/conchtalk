/// OpenAIFormatStrategy：OpenAI 兼容 API 的线上格式实现。
/// 适用于 OpenAI、DeepSeek、及所有 OpenAI 兼容端点。
import Foundation

nonisolated struct OpenAIFormatStrategy: APIFormatStrategy {

    /// 主循环流式请求的 `reasoning_effort`（用户在设置中选择思考力度时才发送）；nil 不发送。
    let reasoningEffort: String?

    init(reasoningEffort: String? = nil) {
        self.reasoningEffort = reasoningEffort
    }

    /// 返回去掉 reasoning_effort 的副本（端点 400 拒绝该参数时自愈重试）。
    func withoutReasoningEffort() -> OpenAIFormatStrategy {
        OpenAIFormatStrategy(reasoningEffort: nil)
    }

    /// 剔除消息上的私有键（`_` 前缀，如 Anthropic thinking 块），避免严格的兼容端点报未知字段。
    static func sanitizedMessages(_ messages: [[String: Any]]) -> [[String: Any]] {
        messages.map { message in
            guard message.keys.contains(where: { $0.hasPrefix("_") }) else { return message }
            return message.filter { !$0.key.hasPrefix("_") }
        }
    }

    /// 流结束后把按 index 累积的原始工具调用转换为 `ToolCall`。
    /// `finish_reason == "length"` 时参数 JSON 不完整的调用标记为截断，交由执行层反馈给模型。
    static func finalizeToolCalls(
        _ raw: [(id: String?, name: String?, args: String)],
        finishReason: String?
    ) -> [ToolCall] {
        raw.compactMap { tc in
            guard let id = tc.id, let name = tc.name else { return nil }
            // 无参数工具：部分服务商不发送 arguments，视为空对象
            let argData = (tc.args.isEmpty ? "{}" : tc.args).data(using: .utf8) ?? Data()
            let explanation: String
            if let args = try? JSONSerialization.jsonObject(with: argData) as? [String: Any],
               let expl = args["explanation"] as? String {
                explanation = expl
            } else {
                explanation = name
            }
            var toolCall = ToolCall(id: id, toolName: name, argumentsJSON: argData, explanation: explanation)
            if finishReason == "length" && !toolCall.hasValidArgumentsJSON {
                toolCall.truncatedByMaxTokens = true
            }
            return toolCall
        }
    }

    /// 回复文本被截断（finish_reason=length）时追加的提示（英文：会作为 assistant 文本回放给模型）。
    static func truncationNotice(hadText: Bool) -> String {
        (hadText ? "\n\n" : "") + "[Reply cut off: the model reached its output token limit. Send “continue” to let it finish.]"
    }

    /// 请求体序列化：`.sortedKeys` 保证字典键顺序稳定，使相同前缀的请求字节一致，
    /// 以命中 OpenAI 等服务商的自动前缀缓存（Swift 字典遍历顺序会随机化）。
    static func serialize(_ body: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    /// 解析 chunk 中的 usage（OpenAI 仅在请求 stream_options.include_usage 时于最后一个 chunk 返回；
    /// 部分兼容服务商默认返回）。本端不主动请求，避免不支持 stream_options 的服务商报错。
    static func parseUsage(from chunk: [String: Any]) -> StreamingTokenUsage? {
        guard let raw = chunk["usage"] as? [String: Any] else { return nil }
        var usage = StreamingTokenUsage()
        usage.inputTokens = raw["prompt_tokens"] as? Int
        usage.outputTokens = raw["completion_tokens"] as? Int
        if let details = raw["prompt_tokens_details"] as? [String: Any] {
            usage.cacheReadInputTokens = details["cached_tokens"] as? Int
        }
        return usage.isEmpty ? nil : usage
    }

    // MARK: - Headers

    func setAuthHeaders(on request: inout URLRequest, apiKey: String) {
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("ConchTalk", forHTTPHeaderField: "X-Title")
    }

    // MARK: - Request Body

    func buildStreamingRequestBody(
        messages: [[String: Any]],
        model: String,
        toolDefinitions: [[String: Any]]
    ) throws -> Data {
        var body: [String: Any] = [
            "messages": Self.sanitizedMessages(messages),
            "stream": true,
        ]
        if !model.isEmpty {
            body["model"] = model
        }
        if !toolDefinitions.isEmpty {
            body["tools"] = toolDefinitions
        }
        if let reasoningEffort {
            body["reasoning_effort"] = reasoningEffort
        }
        return try Self.serialize(body)
    }

    func buildNonStreamingRequestBody(
        messages: [[String: Any]],
        model: String,
        maxTokens: Int?,
        temperature: Double?,
        reasoningEffort: String?
    ) throws -> Data {
        var body: [String: Any] = [
            "messages": Self.sanitizedMessages(messages),
            "stream": false,
        ]
        if !model.isEmpty {
            body["model"] = model
        }
        if let maxTokens { body["max_tokens"] = maxTokens }
        if let temperature { body["temperature"] = temperature }
        // 推理模型支持 reasoning_effort 参数，不支持的模型会忽略此字段
        if let reasoningEffort { body["reasoning_effort"] = reasoningEffort }
        return try Self.serialize(body)
    }

    // MARK: - Response Parsing

    func processSSEStream(
        bytes: URLSession.AsyncBytes,
        continuation: AsyncStream<StreamingDelta>.Continuation
    ) async {
        var toolCalls: [(id: String?, name: String?, args: String)] = []
        var finishReason: String?
        var producedText = false

        do {
            for try await line in bytes.lines {
                try Task.checkCancellation()
                guard line.hasPrefix("data: ") else { continue }
                let payload = String(line.dropFirst(6))
                if payload == "[DONE]" { break }

                guard let data = payload.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    continue
                }

                // usage 通常在 choices 为空的最后一个 chunk 中
                if let usage = Self.parseUsage(from: json) {
                    continuation.yield(.usage(usage))
                }

                guard let choices = json["choices"] as? [[String: Any]],
                      let choice = choices.first else {
                    continue
                }
                if let reason = choice["finish_reason"] as? String {
                    finishReason = reason
                }
                guard let delta = choice["delta"] as? [String: Any] else {
                    continue
                }

                // Reasoning content (DeepSeek R1, etc.)
                if let reasoning = delta["reasoning_content"] as? String, !reasoning.isEmpty {
                    continuation.yield(.reasoning(reasoning))
                }

                // Content
                if let content = delta["content"] as? String, !content.isEmpty {
                    producedText = true
                    continuation.yield(.content(content))
                }

                // Tool calls（按 index 累积，支持多个并行 tool call）
                if let toolCallsArray = delta["tool_calls"] as? [[String: Any]] {
                    for tc in toolCallsArray {
                        let index = tc["index"] as? Int ?? 0
                        while toolCalls.count <= index {
                            toolCalls.append((id: nil, name: nil, args: ""))
                        }
                        if let id = tc["id"] as? String {
                            toolCalls[index].id = id
                        }
                        if let function = tc["function"] as? [String: Any] {
                            if let name = function["name"] as? String {
                                // 清理开源模型可能泄漏的特殊 token 后缀（如 <|channel|>、<|end|> 等）
                                let cleanName = name.replacingOccurrences(
                                    of: "<\\|[^|]+\\|>",
                                    with: "",
                                    options: .regularExpression
                                )
                                toolCalls[index].name = cleanName
                            }
                            if let args = function["arguments"] as? String {
                                toolCalls[index].args += args
                            }
                        }
                    }
                }
            }

            // 为每个完整的 tool call 生成独立的 .toolCall 事件
            let finalized = Self.finalizeToolCalls(toolCalls, finishReason: finishReason)
            for toolCall in finalized {
                continuation.yield(.toolCall(toolCall))
            }
            if finalized.isEmpty && finishReason == "length" {
                continuation.yield(.content(Self.truncationNotice(hadText: producedText)))
            }

            continuation.yield(.done)
            continuation.finish()
        } catch {
            continuation.yield(.error(error))
            continuation.finish()
        }
    }

    func parseNonStreamingContent(from data: Data) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any] else {
            print("[OpenAI Parse] Failed to parse response: \(String(data: data, encoding: .utf8)?.prefix(500) ?? "nil")")
            throw AIServiceError.invalidResponse
        }
        // 优先取 content 字段
        if let content = message["content"] as? String {
            return content.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // 推理模型可能 content=null，但 reasoning/reasoning_content 有值；
        // 检查是否因 max_tokens 截断导致 content 为空
        let finishReason = first["finish_reason"] as? String
        if finishReason == "length" {
            print("[OpenAI Parse] Response truncated (finish_reason=length), content is null. Reasoning model likely needs more tokens.")
        }
        print("[OpenAI Parse] message.content is null, keys: \(message.keys.sorted()), finish_reason: \(finishReason ?? "nil")")
        throw AIServiceError.invalidResponse
    }

    func parseError(data: Data, statusCode: Int) -> AIServiceError {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            // 新后端扁平格式: { "error": "description" }
            if let message = json["error"] as? String {
                return .apiError(statusCode: statusCode, message: message)
            }
            // OpenAI 嵌套格式: { "error": { "message": "..." } }
            if let errorObj = json["error"] as? [String: Any],
               let message = errorObj["message"] as? String {
                return .apiError(statusCode: statusCode, message: message)
            }
        }
        let raw = String(data: data, encoding: .utf8) ?? "Unknown error"
        return .apiError(statusCode: statusCode, message: raw)
    }
}
