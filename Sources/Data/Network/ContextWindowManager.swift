/// 文件说明：ContextWindowManager，负责上下文占用估算与历史消息压缩策略。
import Foundation

/// ContextWindowManager：提供上下文窗口估算与压缩的静态能力。
enum ContextWindowManager {

    // MARK: - Token Estimation

    /// 估算单段文本 token 数（CJK + ASCII 启发式）。
    /// - Parameter text: 输入文本。
    /// - Returns: 估算 token 数（至少为 1）。
    /// - Note:
    ///   - CJK 按每字符约 1.5~2 token 估算。
    ///   - ASCII 连续串按约 4 字符 1 token 估算。
    static func estimateTokens(for text: String) -> Int {
        var tokens = 0
        var asciiRun = 0

        for scalar in text.unicodeScalars {
            if (0x4E00...0x9FFF).contains(scalar.value) ||
               (0x3400...0x4DBF).contains(scalar.value) ||
               (0xF900...0xFAFF).contains(scalar.value) {
                // Flush ASCII run
                tokens += asciiRun / 4
                asciiRun = 0
                // CJK: ~1.5 tokens per character
                tokens += 2  // round up per-char (3 tokens per 2 chars)
            } else {
                asciiRun += 1
            }
        }
        // Flush remaining ASCII
        tokens += asciiRun / 4
        return max(tokens, 1)
    }

    /// 估算 OpenAI `messages` 数组总 token。
    /// - Parameter messages: OpenAI 协议消息数组。
    /// - Returns: 估算 token 总数。
    /// - Note: 结果包含消息结构开销、tool_calls JSON 开销与 reasoning_content 开销。
    static func estimateTokens(for messages: [[String: Any]]) -> Int {
        var total = 0
        for msg in messages {
            total += messageTokens(msg)
        }
        return total
    }

    /// 估算单条 OpenAI 协议消息的 token 数。
    private static func messageTokens(_ msg: [String: Any]) -> Int {
        var tokens = 4 // per-message overhead (role, formatting)

        if let content = msg["content"] as? String {
            tokens += estimateTokens(for: content)
        }

        // tool_calls JSON
        if let toolCalls = msg["tool_calls"] {
            if let data = try? JSONSerialization.data(withJSONObject: toolCalls),
               let str = String(data: data, encoding: .utf8) {
                tokens += estimateTokens(for: str)
            }
        }

        // reasoning_content (DeepSeek R1, etc.)
        if let reasoning = msg["reasoning_content"] as? String, !reasoning.isEmpty {
            tokens += estimateTokens(for: reasoning)
        }

        return tokens
    }

    /// 估算上下文窗口占用比例。
    /// - Parameters:
    ///   - messages: 会话消息（自动跳过 loading 占位消息）。
    ///   - systemPrompt: 系统提示词。
    ///   - toolDefinitions: 工具定义数组。
    ///   - maxTokens: 上下文上限。
    /// - Returns: 占用比例（`0...1+`，大于 1 表示超限风险）。
    /// - Note: 用于 UI 提示与压缩触发，不等同于服务端精确计量。
    static func usagePercent(
        messages: [Message],
        systemPrompt: String,
        toolDefinitions: [[String: Any]],
        maxTokens: Int
    ) -> Double {
        guard maxTokens > 0 else { return 0 }

        var tokens = 4 + estimateTokens(for: systemPrompt)

        // Tool definitions overhead
        if let data = try? JSONSerialization.data(withJSONObject: toolDefinitions),
           let str = String(data: data, encoding: .utf8) {
            tokens += estimateTokens(for: str)
        }

        for msg in messages where !msg.isLoading {
            tokens += 4 // per-message overhead
            tokens += estimateTokens(for: msg.content)
            if let toolCall = msg.toolCall {
                let argsStr = String(data: toolCall.argumentsJSON, encoding: .utf8) ?? "{}"
                tokens += estimateTokens(for: argsStr)
                tokens += estimateTokens(for: toolCall.toolName)
                tokens += 20 // tool_call structure overhead
            }
            if let output = msg.toolOutput {
                tokens += estimateTokens(for: output)
            }
            if let reasoning = msg.reasoningContent {
                tokens += estimateTokens(for: reasoning)
            }
        }

        return Double(tokens) / Double(maxTokens)
    }

    // MARK: - Compression

    /// 在上下文压力过高时压缩历史消息。
    /// - Parameters:
    ///   - messages: 原始 OpenAI 消息数组（首条应为 system）。
    ///   - maxTokens: 上下文上限。
    ///   - cachedSummary: 上轮可复用摘要（可选）。
    ///   - using: 用于生成摘要的网络会话。
    ///   - settings: AI 设置。
    /// - Returns: 压缩后消息数组与可复用摘要。
    /// - Throws: 摘要请求网络失败或序列化失败时抛出。
    /// - Strategy:
    ///   - 仅当估算 token 超过上限 85% 时触发压缩。
    ///   - 预算按 `maxTokens * 0.70` 保留 system + 最近消息。
    ///   - 更早消息折叠为一条摘要系统消息。
    /// - Side Effects: 可能发起一次额外摘要请求。
    static func compress(
        messages: [[String: Any]],
        maxTokens: Int,
        cachedSummary: String?,
        using session: URLSession,
        settings: AISettings
    ) async throws -> (compressed: [[String: Any]], summary: String?) {
        let currentTokens = estimateTokens(for: messages)

        // 超过阈值才压缩，避免高频抖动。
        guard Double(currentTokens) > Double(maxTokens) * 0.95 else {
            return (messages, cachedSummary)
        }

        guard messages.count > 2 else {
            return (messages, cachedSummary)
        }

        let systemMessage = messages[0] // system prompt
        let contentMessages = Array(messages.dropFirst())

        // 预算保留给 system + 最近消息，并为模型回复预留空间。
        let budget = Int(Double(maxTokens) * 0.70)
        let systemTokens = 4 + estimateTokens(for: systemMessage["content"] as? String ?? "")

        // 反向遍历，寻找可保留的"最近消息"切分点。
        var recentTokens = systemTokens
        var splitIndex = contentMessages.count

        for i in stride(from: contentMessages.count - 1, through: 0, by: -1) {
            let msgTok = messageTokens(contentMessages[i])
            if recentTokens + msgTok > budget {
                splitIndex = i + 1
                break
            }
            recentTokens += msgTok
            if i == 0 { splitIndex = 0 }
        }

        // 无可裁剪历史时直接返回。
        guard splitIndex > 0 else {
            return (messages, cachedSummary)
        }

        let oldMessages = Array(contentMessages[..<splitIndex])
        let recentMessages = Array(contentMessages[splitIndex...])

        // 优先复用缓存摘要，避免重复调用摘要接口。
        let summary: String
        if let cached = cachedSummary {
            summary = cached
        } else {
            summary = try await generateSummary(
                for: oldMessages,
                using: session,
                settings: settings
            )
        }

        // 组装压缩后消息：system + summary + recent
        var result: [[String: Any]] = [systemMessage]

        if !summary.isEmpty {
            result.append([
                "role": "system",
                "content": "[Previous conversation summary]\n\(summary)",
            ])
        }

        result.append(contentsOf: recentMessages)
        return (result, summary)
    }

    // MARK: - Summary Generation

    /// 生成旧消息摘要文本。
    /// - Parameters:
    ///   - messages: 待摘要的历史消息。
    ///   - using: 网络会话。
    ///   - settings: AI 设置。
    /// - Returns: 摘要文本；若摘要失败且可降级时返回空字符串。
    /// - Throws: 请求体序列化或网络请求异常时抛出。
    /// - Error Handling:
    ///   - API Key 缺失、HTTP 非 2xx、响应结构不合法时返回空字符串以降级继续。
    private static func generateSummary(
        for messages: [[String: Any]],
        using session: URLSession,
        settings: AISettings
    ) async throws -> String {
        guard !settings.apiKey.isEmpty else { return "" }

        let baseURL = settings.baseURL.isEmpty
            ? "https://api.openai.com/v1"
            : settings.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let url = URL(string: "\(baseURL)/chat/completions")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(settings.apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30

        // 构建紧凑历史文本，降低摘要提示词体积。
        var conversationText = ""
        for msg in messages {
            let role = msg["role"] as? String ?? "unknown"
            let content = msg["content"] as? String ?? ""
            if !content.isEmpty {
                conversationText += "\(role): \(content)\n"
            }
        }

        let summaryPrompt = """
        Summarize the following conversation in under 200 words. \
        Keep key facts, decisions, and command results. \
        Write in the same language as the conversation.

        \(conversationText)
        """

        let body: [String: Any] = [
            "model": settings.modelName,
            "messages": [
                ["role": "user", "content": summaryPrompt],
            ],
            "max_tokens": 300,
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            return ""
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let choice = choices.first,
              let message = choice["message"] as? [String: Any],
              let content = message["content"] as? String else {
            return ""
        }

        return content
    }
}
