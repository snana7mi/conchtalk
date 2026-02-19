import Foundation

final class AIProxyService: AIServiceProtocol, @unchecked Sendable {
    private let session: URLSession
    private let keychainService: KeychainServiceProtocol
    private let toolRegistry: ToolRegistryProtocol
    private var cachedSummary: String?

    init(keychainService: KeychainServiceProtocol, toolRegistry: ToolRegistryProtocol) {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        self.session = URLSession(configuration: config)
        self.keychainService = keychainService
        self.toolRegistry = toolRegistry
    }

    // MARK: - AIServiceProtocol

    func sendMessage(_ message: String, conversationHistory: [Message], serverContext: String) async throws -> AIResponse {
        var messages = buildOpenAIMessages(from: conversationHistory, serverContext: serverContext)
        messages.append(["role": "user", "content": message])
        messages = try await compressIfNeeded(messages)
        return try await callOpenAI(messages: messages)
    }

    func sendToolResult(_ result: String, forToolCall toolCall: ToolCall, conversationHistory: [Message], serverContext: String) async throws -> AIResponse {
        var messages = buildOpenAIMessages(from: conversationHistory, serverContext: serverContext)
        messages = try await compressIfNeeded(messages)
        return try await callOpenAI(messages: messages)
    }

    // MARK: - Context Usage

    func estimateContextUsage(history: [Message], serverContext: String) -> Double {
        let settings = AISettings.load()
        let systemPrompt = Self.systemPrompt(serverContext: serverContext, tools: toolRegistry.tools)
        return ContextWindowManager.usagePercent(
            messages: history,
            systemPrompt: systemPrompt,
            toolDefinitions: toolRegistry.openAIToolDefinitions(),
            maxTokens: settings.maxContextTokens
        )
    }

    // MARK: - Compression

    private func compressIfNeeded(_ messages: [[String: Any]]) async throws -> [[String: Any]] {
        let settings = AISettings.load()
        let (compressed, summary) = try await ContextWindowManager.compress(
            messages: messages,
            maxTokens: settings.maxContextTokens,
            cachedSummary: cachedSummary,
            using: session,
            settings: settings
        )
        cachedSummary = summary
        return compressed
    }

    // MARK: - OpenAI API

    private func callOpenAI(messages: [[String: Any]]) async throws -> AIResponse {
        let settings = AISettings.load()
        guard !settings.apiKey.isEmpty else {
            throw AIServiceError.apiKeyMissing
        }

        let baseURL = settings.baseURL.isEmpty ? "https://api.openai.com/v1" : settings.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let url = URL(string: "\(baseURL)/chat/completions")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(settings.apiKey)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = [
            "model": settings.modelName,
            "messages": messages,
            "tools": toolRegistry.openAIToolDefinitions(),
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIServiceError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw AIServiceError.apiError(statusCode: httpResponse.statusCode, message: errorBody)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let choice = choices.first,
              let message = choice["message"] as? [String: Any] else {
            throw AIServiceError.invalidResponse
        }

        // Check for tool calls (generic — works for any registered tool)
        if let toolCalls = message["tool_calls"] as? [[String: Any]],
           let firstToolCall = toolCalls.first,
           let toolCallID = firstToolCall["id"] as? String,
           let function = firstToolCall["function"] as? [String: Any],
           let name = function["name"] as? String,
           let argumentsString = function["arguments"] as? String,
           let argData = argumentsString.data(using: .utf8) {

            // Extract explanation from arguments if present, otherwise use tool name
            let explanation: String
            if let args = try? JSONSerialization.jsonObject(with: argData) as? [String: Any],
               let expl = args["explanation"] as? String {
                explanation = expl
            } else {
                explanation = name
            }

            let toolCall = ToolCall(
                id: toolCallID,
                toolName: name,
                argumentsJSON: argData,
                explanation: explanation
            )
            let reasoning = message["reasoning_content"] as? String
            return .toolCall(toolCall, reasoning: reasoning)
        }

        // Text response
        let content = message["content"] as? String ?? ""
        let reasoning = message["reasoning_content"] as? String
        return .text(content, reasoning: reasoning)
    }

    // MARK: - Streaming API

    func sendMessageStreaming(_ message: String, conversationHistory: [Message], serverContext: String) -> AsyncStream<StreamingDelta> {
        AsyncStream { continuation in
            Task {
                do {
                    var messages = buildOpenAIMessages(from: conversationHistory, serverContext: serverContext)
                    messages.append(["role": "user", "content": message])
                    messages = try await compressIfNeeded(messages)
                    await callOpenAIStreaming(messages: messages, continuation: continuation)
                } catch {
                    continuation.yield(.error(error))
                    continuation.finish()
                }
            }
        }
    }

    func sendToolResultStreaming(_ result: String, forToolCall toolCall: ToolCall, conversationHistory: [Message], serverContext: String) -> AsyncStream<StreamingDelta> {
        AsyncStream { continuation in
            Task {
                do {
                    var messages = buildOpenAIMessages(from: conversationHistory, serverContext: serverContext)
                    messages = try await compressIfNeeded(messages)
                    await callOpenAIStreaming(messages: messages, continuation: continuation)
                } catch {
                    continuation.yield(.error(error))
                    continuation.finish()
                }
            }
        }
    }

    private func callOpenAIStreaming(messages: [[String: Any]], continuation: AsyncStream<StreamingDelta>.Continuation) async {
        let settings = AISettings.load()
        guard !settings.apiKey.isEmpty else {
            continuation.yield(.error(AIServiceError.apiKeyMissing))
            continuation.finish()
            return
        }

        let baseURL = settings.baseURL.isEmpty ? "https://api.openai.com/v1" : settings.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(baseURL)/chat/completions") else {
            continuation.yield(.error(AIServiceError.invalidResponse))
            continuation.finish()
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(settings.apiKey)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = [
            "model": settings.modelName,
            "messages": messages,
            "tools": toolRegistry.openAIToolDefinitions(),
            "stream": true,
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            continuation.yield(.error(error))
            continuation.finish()
            return
        }

        do {
            let (bytes, response) = try await session.bytes(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                continuation.yield(.error(AIServiceError.apiError(statusCode: statusCode, message: "Streaming request failed")))
                continuation.finish()
                return
            }

            // Accumulate tool call pieces across chunks
            var toolCallID: String?
            var toolCallName: String?
            var toolCallArgs = ""
            var hasToolCall = false

            for try await line in bytes.lines {
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

                // Tool calls (accumulated across chunks)
                if let toolCalls = delta["tool_calls"] as? [[String: Any]],
                   let tc = toolCalls.first {
                    hasToolCall = true
                    if let id = tc["id"] as? String {
                        toolCallID = id
                    }
                    if let function = tc["function"] as? [String: Any] {
                        if let name = function["name"] as? String {
                            toolCallName = name
                        }
                        if let args = function["arguments"] as? String {
                            toolCallArgs += args
                        }
                    }
                }
            }

            // If we accumulated a complete tool call, yield it
            if hasToolCall,
               let id = toolCallID,
               let name = toolCallName,
               let argData = toolCallArgs.data(using: .utf8) {
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

            continuation.yield(.done)
            continuation.finish()
        } catch {
            continuation.yield(.error(error))
            continuation.finish()
        }
    }

    // MARK: - Message Conversion

    private func buildOpenAIMessages(from history: [Message], serverContext: String) -> [[String: Any]] {
        var openAIMessages: [[String: Any]] = []

        // System prompt
        openAIMessages.append([
            "role": "system",
            "content": Self.systemPrompt(serverContext: serverContext, tools: toolRegistry.tools),
        ])

        for msg in history where !msg.isLoading {
            switch msg.role {
            case .user:
                openAIMessages.append(["role": "user", "content": msg.content])
            case .assistant:
                openAIMessages.append(["role": "assistant", "content": msg.content])
            case .command:
                if let toolCall = msg.toolCall {
                    let argsString = String(data: toolCall.argumentsJSON, encoding: .utf8) ?? "{}"

                    // Assistant message with tool call
                    openAIMessages.append([
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
                    ])

                    // Tool response
                    openAIMessages.append([
                        "role": "tool",
                        "tool_call_id": toolCall.id,
                        "content": msg.toolOutput ?? "",
                    ])
                }
            case .system:
                openAIMessages.append(["role": "user", "content": "[System: \(msg.content)]"])
            }
        }

        return openAIMessages
    }

    // MARK: - System Prompt

    private static func systemPrompt(serverContext: String, tools: [ToolProtocol]) -> String {
        let toolList = tools.map { "- \($0.name): \($0.description)" }.joined(separator: "\n")

        return """
        You are ConchTalk, an intelligent SSH assistant. You help users manage remote servers through natural language conversations.

        ## Your Role
        - Translate user requests into tool calls to manage the remote server
        - Execute tools step by step, analyzing results before proceeding
        - Provide clear explanations in the user's language (Chinese or English, match the user)
        - When a task requires multiple steps, execute them one at a time

        ## Server Context
        \(serverContext)

        ## Available Tools
        \(toolList)

        ## Rules
        1. Use the appropriate tool for each task
        2. For read-only operations, prefer specialized tools (read_file, list_directory, get_system_info, etc.)
        3. Use execute_ssh_command as a general-purpose fallback when no specialized tool fits
        4. For execute_ssh_command: set is_destructive to false for read-only commands, true for write/modify operations
        5. Never execute obviously dangerous commands like "rm -rf /", "mkfs", "dd if=/dev/zero" etc.
        6. Always provide a clear explanation of what each tool call does
        7. After executing a tool, analyze the output and decide the next step
        8. When the task is complete, provide a summary in natural language (not a tool call)
        9. If a tool call fails, explain the error and suggest alternatives
        10. Keep explanations concise but informative
        11. Always match the user's language (if they write in Chinese, respond in Chinese)
        """
    }
}

// MARK: - AI Settings (stored in UserDefaults + Keychain)

struct AISettings {
    var apiKey: String
    var baseURL: String
    var modelName: String
    var maxContextTokensK: Int  // Unit: K (e.g. 128 = 128,000 tokens)

    var maxContextTokens: Int { maxContextTokensK * 1000 }

    static func load() -> AISettings {
        let defaults = UserDefaults.standard
        let storedK = defaults.integer(forKey: "aiMaxContextTokensK")
        return AISettings(
            apiKey: defaults.string(forKey: "aiAPIKey") ?? "",
            baseURL: defaults.string(forKey: "aiBaseURL") ?? "",
            modelName: defaults.string(forKey: "aiModelName") ?? "gpt-4o",
            maxContextTokensK: storedK > 0 ? storedK : 128
        )
    }

    func save() {
        let defaults = UserDefaults.standard
        defaults.set(apiKey, forKey: "aiAPIKey")
        defaults.set(baseURL, forKey: "aiBaseURL")
        defaults.set(modelName, forKey: "aiModelName")
        defaults.set(maxContextTokensK, forKey: "aiMaxContextTokensK")
    }
}

// MARK: - Errors

enum AIServiceError: LocalizedError {
    case apiKeyMissing
    case invalidResponse
    case apiError(statusCode: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .apiKeyMissing: return "API Key not configured. Go to Settings to add your API key."
        case .invalidResponse: return "Invalid response from AI service"
        case .apiError(let code, let msg): return "AI API error (\(code)): \(msg)"
        }
    }
}
