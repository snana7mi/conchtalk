/// OpenAIFormatStrategy：OpenAI 兼容 API 的线上格式实现。
/// 适用于 OpenAI、DeepSeek、及所有 OpenAI 兼容端点。
import Foundation

nonisolated struct OpenAIFormatStrategy: APIFormatStrategy {

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
            "messages": messages,
            "stream": true,
        ]
        if !model.isEmpty {
            body["model"] = model
        }
        if !toolDefinitions.isEmpty {
            body["tools"] = toolDefinitions
        }
        return try JSONSerialization.data(withJSONObject: body)
    }

    func buildNonStreamingRequestBody(
        messages: [[String: Any]],
        model: String,
        maxTokens: Int?,
        temperature: Double?,
        reasoningEffort: String?
    ) throws -> Data {
        var body: [String: Any] = [
            "messages": messages,
            "stream": false,
        ]
        if !model.isEmpty {
            body["model"] = model
        }
        if let maxTokens { body["max_tokens"] = maxTokens }
        if let temperature { body["temperature"] = temperature }
        // 推理模型支持 reasoning_effort 参数，不支持的模型会忽略此字段
        if let reasoningEffort { body["reasoning_effort"] = reasoningEffort }
        return try JSONSerialization.data(withJSONObject: body)
    }

    // MARK: - Response Parsing

    func processSSEStream(
        bytes: URLSession.AsyncBytes,
        continuation: AsyncStream<StreamingDelta>.Continuation
    ) async {
        var toolCalls: [(id: String?, name: String?, args: String)] = []

        do {
            for try await line in bytes.lines {
                try Task.checkCancellation()
                guard line.hasPrefix("data: ") else { continue }
                let payload = String(line.dropFirst(6))
                if payload == "[DONE]" { break }

                guard let data = payload.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let choices = json["choices"] as? [[String: Any]],
                      let choice = choices.first,
                      let delta = choice["delta"] as? [String: Any] else {
                    continue
                }

                // Reasoning content (DeepSeek R1, etc.)
                if let reasoning = delta["reasoning_content"] as? String, !reasoning.isEmpty {
                    continuation.yield(.reasoning(reasoning))
                }

                // Content
                if let content = delta["content"] as? String, !content.isEmpty {
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
            for tc in toolCalls {
                if let id = tc.id,
                   let name = tc.name,
                   let argData = tc.args.data(using: .utf8) {
                    let explanation: String
                    if let args = try? JSONSerialization.jsonObject(with: argData) as? [String: Any],
                       let expl = args["explanation"] as? String {
                        explanation = expl
                    } else {
                        explanation = name
                    }
                    let toolCall = ToolCall(id: id, toolName: name, argumentsJSON: argData, explanation: explanation)
                    continuation.yield(.toolCall(toolCall))
                }
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
