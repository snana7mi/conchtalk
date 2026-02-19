/// 文件说明：AIProxyService，负责 OpenAI 请求编排、流式事件解析、重试与上下文压缩。
import Foundation

/// AIProxyService：
/// `AIServiceProtocol` 的基础设施实现，统一处理消息协议转换、压缩决策、
/// 非流式/流式调用与连接丢失重试，向上层提供稳定的 AI 调用语义。
final class AIProxyService: AIServiceProtocol, @unchecked Sendable {
    private let session: URLSession
    private let keychainService: KeychainServiceProtocol
    private let toolRegistry: ToolRegistryProtocol
    private var cachedSummary: String?

    /// 初始化 AI 服务客户端。
    /// - Parameters:
    ///   - keychainService: 凭据服务（预留给后续扩展，当前主要使用本地设置中的 API Key）。
    ///   - toolRegistry: 工具注册表，用于注入 `tools` 定义与系统提示词。
    /// - Side Effects: 创建带 120 秒请求超时的 `URLSession`。
    init(keychainService: KeychainServiceProtocol, toolRegistry: ToolRegistryProtocol) {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        self.session = URLSession(configuration: config)
        self.keychainService = keychainService
        self.toolRegistry = toolRegistry
    }

    // MARK: - AIServiceProtocol

    /// 发送用户消息（非流式）并返回单次 AI 响应。
    /// - Parameters:
    ///   - message: 用户输入文本。
    ///   - conversationHistory: 当前会话历史。
    ///   - serverContext: 服务器上下文信息。
    /// - Returns: 文本响应或工具调用响应。
    /// - Throws: 配置缺失、网络失败、压缩失败或响应解析异常时抛出。
    /// - Side Effects: 可能更新内部 `cachedSummary`（当触发上下文压缩时）。
    func sendMessage(_ message: String, conversationHistory: [Message], serverContext: String) async throws -> AIResponse {
        var messages = buildOpenAIMessages(from: conversationHistory, serverContext: serverContext)
        messages.append(["role": "user", "content": message])
        messages = try await compressIfNeeded(messages)
        return try await callOpenAI(messages: messages)
    }

    /// 在工具执行后继续对话（非流式），让模型基于历史上下文生成下一步响应。
    /// - Parameters:
    ///   - result: 工具输出文本。
    ///   - toolCall: 对应的工具调用信息。
    ///   - conversationHistory: 当前会话历史。
    ///   - serverContext: 服务器上下文信息。
    /// - Returns: 文本响应或新的工具调用响应。
    /// - Throws: 配置缺失、网络失败、压缩失败或响应解析异常时抛出。
    /// - Note: 实际上下文来自 `conversationHistory` 内的 command/tool 记录，
    ///   `result` 与 `toolCall` 主要用于与协议签名保持一致。
    /// - Side Effects: 可能更新内部 `cachedSummary`。
    func sendToolResult(_ result: String, forToolCall toolCall: ToolCall, conversationHistory: [Message], serverContext: String) async throws -> AIResponse {
        var messages = buildOpenAIMessages(from: conversationHistory, serverContext: serverContext)
        messages = try await compressIfNeeded(messages)
        return try await callOpenAI(messages: messages)
    }

    // MARK: - Context Usage

    /// 估算当前历史消息占模型上下文窗口的比例（`0...1+`）。
    /// - Note: 为启发式估算结果，用于 UI 告警与压缩触发判断，不保证与服务端计费完全一致。
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

    /// 根据上下文占用情况压缩消息，并缓存摘要降低重复摘要成本。
    /// - Parameter messages: OpenAI 协议格式的消息数组。
    /// - Returns: 可能被压缩后的消息数组。
    /// - Throws: 摘要请求失败或压缩过程异常时抛出。
    /// - Strategy:
    ///   - 仅当上下文估算超过阈值时触发压缩。
    ///   - 保留 system + 最近消息，把更早历史折叠为摘要系统消息。
    /// - Side Effects: 成功压缩后会刷新 `cachedSummary`。
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

    /// 调用 `/chat/completions`（非流式）并解析为 `AIResponse`。
    /// - Parameter messages: OpenAI 协议格式的消息数组。
    /// - Returns: 文本响应或工具调用响应。
    /// - Throws: API Key 缺失、请求构建失败、HTTP 错误或响应结构不合法时抛出。
    /// - Important: 当响应包含 `tool_calls` 时优先返回 `.toolCall`。
    /// - Error Handling: 若工具调用参数不是合法 JSON，会降级为普通文本分支继续处理。
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

        let (data, response) = try await dataWithRetry(for: request)

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

    /// 流式发送用户消息并持续产出 `StreamingDelta`。
    /// - Returns: 不抛错的 `AsyncStream`；错误通过 `.error` 事件传递。
    /// - Side Effects: 可能更新内部 `cachedSummary`。
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

    /// 流式提交工具输出并持续产出后续 `StreamingDelta`。
    /// - Note: 实际上下文来自 `conversationHistory`，参数 `result/toolCall`
    ///   主要用于与协议签名保持一致。
    /// - Returns: 不抛错的 `AsyncStream`；错误通过 `.error` 事件传递。
    /// - Side Effects: 可能更新内部 `cachedSummary`。
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

    /// 执行流式请求并将 SSE 增量事件转换为 `StreamingDelta`。
    /// - Parameters:
    ///   - messages: OpenAI 协议格式消息。
    ///   - continuation: `AsyncStream` continuation，用于回推增量结果。
    /// - Note: 工具调用参数可能分片到多个 chunk，会在结束时组装为完整 `ToolCall`。
    /// - Error Handling:
    ///   - 请求构建、HTTP 状态异常、网络异常会产出 `.error` 并 `finish()`。
    ///   - 单条 SSE 解析失败会被忽略，不中断整条流。
    /// - Side Effects:
    ///   - 按收到顺序触发 `reasoning/content/toolCall/done` 事件。
    ///   - 对每次调用保证最多 `finish()` 一次。
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
            let (bytes, response) = try await bytesWithRetry(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                continuation.yield(.error(AIServiceError.apiError(statusCode: statusCode, message: "Streaming request failed")))
                continuation.finish()
                return
            }

            // 跨 chunk 累积 tool_call 字段，结束时统一组装。
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

            // 若成功组装完整工具调用，则在流末尾补发 `.toolCall` 事件。
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

    // MARK: - Retry for Connection Lost (-1005)

    /// 执行非流式请求，并在连接中断（`-1005`）时按固定策略重试。
    /// - Parameters:
    ///   - request: 已构建的 HTTP 请求。
    ///   - maxRetries: 最大重试次数（默认 1）。
    /// - Returns: 响应数据与响应头。
    /// - Throws: 达到重试上限后抛出最后一次错误。
    /// - Retry Policy:
    ///   - 仅对 `URLError.networkConnectionLost` 重试。
    ///   - 重试间隔固定 500ms，不做指数退避。
    private func dataWithRetry(for request: URLRequest, maxRetries: Int = 1) async throws -> (Data, URLResponse) {
        var lastError: Error?
        for attempt in 0...maxRetries {
            do {
                return try await session.data(for: request)
            } catch let error as URLError where error.code == .networkConnectionLost && attempt < maxRetries {
                lastError = error
                print("[AIProxy] Connection lost (-1005), retrying... (attempt \(attempt + 1))")
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        throw lastError!
    }

    /// 执行流式请求，并在连接中断（`-1005`）时按固定策略重试。
    /// - Parameters:
    ///   - request: 已构建的 HTTP 请求。
    ///   - maxRetries: 最大重试次数（默认 1）。
    /// - Returns: 流式字节序列与响应头。
    /// - Throws: 达到重试上限后抛出最后一次错误。
    /// - Retry Policy:
    ///   - 仅对 `URLError.networkConnectionLost` 重试。
    ///   - 重试间隔固定 500ms，不做指数退避。
    private func bytesWithRetry(for request: URLRequest, maxRetries: Int = 1) async throws -> (URLSession.AsyncBytes, URLResponse) {
        var lastError: Error?
        for attempt in 0...maxRetries {
            do {
                return try await session.bytes(for: request)
            } catch let error as URLError where error.code == .networkConnectionLost && attempt < maxRetries {
                lastError = error
                print("[AIProxy] Connection lost (-1005), retrying stream... (attempt \(attempt + 1))")
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        throw lastError!
    }

    // MARK: - Message Conversion

    /// 将应用内消息模型转换为 OpenAI 协议消息数组。
    /// - Parameters:
    ///   - history: 会话历史消息。
    ///   - serverContext: 服务器上下文信息。
    /// - Returns: 可直接用于 Chat Completions 的 `messages` 数组。
    /// - Important: `command` 消息会拆成 assistant tool_call 与 tool 响应两条记录。
    /// - Note: `system` 角色消息会被包裹为 user 文本以保留历史提示语义。
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

    /// 构建系统提示词，注入服务器上下文与可用工具清单。
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

/// AISettings：封装 AI 相关本地配置（主要存于 `UserDefaults`）。
struct AISettings {
    var apiKey: String
    var baseURL: String
    var modelName: String
    var maxContextTokensK: Int  // Unit: K (e.g. 128 = 128,000 tokens)

    var maxContextTokens: Int { maxContextTokensK * 1000 }

    /// 从本地配置读取 AI 参数。
    /// - Returns: 若未配置则返回包含默认值的设置对象。
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

    /// 将当前 AI 设置写入 `UserDefaults`。
    /// - Side Effects: 覆盖同名键对应的历史配置值。
    func save() {
        let defaults = UserDefaults.standard
        defaults.set(apiKey, forKey: "aiAPIKey")
        defaults.set(baseURL, forKey: "aiBaseURL")
        defaults.set(modelName, forKey: "aiModelName")
        defaults.set(maxContextTokensK, forKey: "aiMaxContextTokensK")
    }
}

// MARK: - Errors

/// AIServiceError：表示 AI 请求构建、网络调用或响应解析阶段的失败原因。
enum AIServiceError: LocalizedError {
    case apiKeyMissing
    case invalidResponse
    case apiError(statusCode: Int, message: String)

    /// 适用于界面展示的错误文案。
    var errorDescription: String? {
        switch self {
        case .apiKeyMissing: return "API Key not configured. Go to Settings to add your API key."
        case .invalidResponse: return "Invalid response from AI service"
        case .apiError(let code, let msg): return "AI API error (\(code)): \(msg)"
        }
    }
}
