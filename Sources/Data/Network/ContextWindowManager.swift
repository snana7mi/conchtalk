import Foundation

enum ContextWindowManager {

    // MARK: - Token Estimation

    /// Estimate token count for a string (mixed CJK + ASCII heuristic).
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

    /// Estimate total tokens for an array of OpenAI messages.
    static func estimateTokens(for messages: [[String: Any]]) -> Int {
        var total = 0
        for msg in messages {
            // Per-message overhead (role, formatting)
            total += 4

            if let content = msg["content"] as? String {
                total += estimateTokens(for: content)
            }

            // tool_calls JSON
            if let toolCalls = msg["tool_calls"] {
                if let data = try? JSONSerialization.data(withJSONObject: toolCalls),
                   let str = String(data: data, encoding: .utf8) {
                    total += estimateTokens(for: str)
                }
            }
        }
        return total
    }

    /// Calculate context usage percentage (0.0 – 1.0+).
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
        }

        return Double(tokens) / Double(maxTokens)
    }

    // MARK: - Compression

    /// Compress messages when exceeding token limit.
    /// Keeps system prompt + recent messages; summarizes old messages via an extra API call.
    static func compress(
        messages: [[String: Any]],
        maxTokens: Int,
        cachedSummary: String?,
        using session: URLSession,
        settings: AISettings
    ) async throws -> (compressed: [[String: Any]], summary: String?) {
        let currentTokens = estimateTokens(for: messages)

        // Only compress when > 85% of maxTokens
        guard Double(currentTokens) > Double(maxTokens) * 0.85 else {
            return (messages, cachedSummary)
        }

        guard messages.count > 2 else {
            return (messages, cachedSummary)
        }

        let systemMessage = messages[0] // system prompt
        let contentMessages = Array(messages.dropFirst())

        // Budget: maxTokens * 0.7 for recent messages (leave room for response)
        let budget = Int(Double(maxTokens) * 0.70)
        let systemTokens = 4 + estimateTokens(for: systemMessage["content"] as? String ?? "")

        // Walk backwards to find how many recent messages fit
        var recentTokens = systemTokens
        var splitIndex = contentMessages.count

        for i in stride(from: contentMessages.count - 1, through: 0, by: -1) {
            let msgTokens = 4 + estimateTokens(for: contentMessages[i]["content"] as? String ?? "")
            if recentTokens + msgTokens > budget {
                splitIndex = i + 1
                break
            }
            recentTokens += msgTokens
            if i == 0 { splitIndex = 0 }
        }

        // If nothing to trim, return as-is
        guard splitIndex > 0 else {
            return (messages, cachedSummary)
        }

        let oldMessages = Array(contentMessages[..<splitIndex])
        let recentMessages = Array(contentMessages[splitIndex...])

        // Generate summary if we don't have a cached one covering these messages
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

        // Build compressed message array
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

        // Build a condensed representation of old messages
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
