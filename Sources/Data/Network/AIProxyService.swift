/// 文件说明：AIProxyService，负责 OpenAI 请求编排、流式事件解析、重试与上下文压缩。
import Foundation

// MARK: - Provider Profile

/// 协议适配层：将不同 LLM 供应商的 reasoning_content 规则显式化。
private protocol ProviderProfile {
    /// assistant + tool_calls 历史消息是否附带 reasoning_content。
    var includeReasoningOnToolCallMessages: Bool { get }
    /// 纯 assistant content 历史消息是否附带 reasoning_content。
    var includeReasoningOnPlainAssistantMessages: Bool { get }
}

/// DeepSeek：只在 assistant + tool_calls 历史上带 reasoning_content。
private struct DeepSeekProfile: ProviderProfile {
    let includeReasoningOnToolCallMessages = true
    let includeReasoningOnPlainAssistantMessages = false
}

/// OpenAI 及其他兼容服务：完全不传 reasoning_content。
private struct DefaultProfile: ProviderProfile {
    let includeReasoningOnToolCallMessages = false
    let includeReasoningOnPlainAssistantMessages = false
}

/// 根据 baseURL / modelName 推断供应商 Profile。
private func resolveProfile(baseURL: String, modelName: String) -> ProviderProfile {
    let url = baseURL.lowercased()
    let model = modelName.lowercased()
    if url.contains("deepseek") || model.contains("deepseek") {
        return DeepSeekProfile()
    }
    return DefaultProfile()
}

/// AIProxyService：
/// `AIServiceProtocol` 的基础设施实现，统一处理消息协议转换、压缩决策、
/// 流式调用与连接丢失重试，向上层提供稳定的 AI 调用语义。
final class AIProxyService: AIServiceProtocol, @unchecked Sendable {
    private let session: URLSession
    private let keychainService: KeychainServiceProtocol
    private let toolRegistry: ToolRegistryProtocol
    private var cachedSummary: String?

    /// 初始化 AI 服务客户端。
    /// - Parameters:
    ///   - keychainService: 凭据服务，用于安全存储和读取 API Key。
    ///   - toolRegistry: 工具注册表，用于注入 `tools` 定义与系统提示词。
    /// - Side Effects: 创建带 120 秒请求超时的 `URLSession`。
    init(keychainService: KeychainServiceProtocol, toolRegistry: ToolRegistryProtocol) {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        self.session = URLSession(configuration: config)
        self.keychainService = keychainService
        self.toolRegistry = toolRegistry
    }

    // MARK: - Context Usage

    /// 估算当前历史消息占模型上下文窗口的比例（`0...1+`）。
    /// - Note: 为启发式估算结果，用于 UI 告警与压缩触发判断，不保证与服务端计费完全一致。
    func estimateContextUsage(history: [Message], serverContext: String) -> Double {
        let settings = AISettings.load(keychainService: keychainService)
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
        let settings = AISettings.load(keychainService: keychainService)
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

                    let healResult = await callOpenAIStreamingWithHealing(messages: messages)
                    switch healResult {
                    case .needsRetry(let hint):
                        let healProfile: ProviderProfile = (hint == .add) ? DeepSeekProfile() : DefaultProfile()
                        var retryMessages = buildOpenAIMessages(
                            from: conversationHistory,
                            serverContext: serverContext,
                            profileOverride: healProfile
                        )
                        retryMessages.append(["role": "user", "content": message])
                        retryMessages = try await compressIfNeeded(retryMessages)
                        await callOpenAIStreaming(messages: retryMessages, continuation: continuation)
                    case .stream(let bytes, let httpResponse):
                        await processSSEStream(bytes: bytes, httpResponse: httpResponse, continuation: continuation)
                    case .error(let error):
                        continuation.yield(.error(error))
                        continuation.finish()
                    }
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

                    let healResult = await callOpenAIStreamingWithHealing(messages: messages)
                    switch healResult {
                    case .needsRetry(let hint):
                        let healProfile: ProviderProfile = (hint == .add) ? DeepSeekProfile() : DefaultProfile()
                        var retryMessages = buildOpenAIMessages(
                            from: conversationHistory,
                            serverContext: serverContext,
                            profileOverride: healProfile
                        )
                        retryMessages = try await compressIfNeeded(retryMessages)
                        await callOpenAIStreaming(messages: retryMessages, continuation: continuation)
                    case .stream(let bytes, let httpResponse):
                        await processSSEStream(bytes: bytes, httpResponse: httpResponse, continuation: continuation)
                    case .error(let error):
                        continuation.yield(.error(error))
                        continuation.finish()
                    }
                } catch {
                    continuation.yield(.error(error))
                    continuation.finish()
                }
            }
        }
    }

    // MARK: - Streaming Internals

    /// 流式自愈预检结果。
    private enum StreamingPreflightResult {
        case stream(URLSession.AsyncBytes, HTTPURLResponse)
        case needsRetry(ReasoningHealingHint)
        case error(Error)
    }

    /// 构建流式请求并发起连接。400 且匹配 reasoning 错误时返回 `.needsRetry`。
    private func callOpenAIStreamingWithHealing(messages: [[String: Any]]) async -> StreamingPreflightResult {
        let settings = AISettings.load(keychainService: keychainService)
        guard !settings.apiKey.isEmpty else {
            return .error(AIServiceError.apiKeyMissing)
        }

        let baseURL = settings.baseURL.isEmpty ? "https://api.openai.com/v1" : settings.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(baseURL)/chat/completions") else {
            return .error(AIServiceError.invalidResponse)
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
            return .error(error)
        }

        do {
            let (bytes, response) = try await bytesWithRetry(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                var errorBytes: [UInt8] = []
                do {
                    for try await byte in bytes {
                        errorBytes.append(byte)
                    }
                } catch {
                    print("[AIProxy] Failed to read streaming error body: \(error)")
                }
                let errorData = Data(errorBytes)
                let apiError = Self.parseAPIError(data: errorData, statusCode: statusCode)

                // 400 自愈：检查是否 reasoning_content 相关
                if statusCode == 400,
                   case .apiError(_, let msg) = apiError,
                   let hint = Self.reasoningHealingHint(from: msg) {
                    print("[AIProxy] Streaming 400 self-healing: \(hint == .add ? "adding" : "removing") reasoning_content and retrying…")
                    return .needsRetry(hint)
                }

                return .error(apiError)
            }

            return .stream(bytes, httpResponse)
        } catch {
            return .error(error)
        }
    }

    /// 不带自愈的直接流式调用（用于重试时的第二次请求）。
    private func callOpenAIStreaming(messages: [[String: Any]], continuation: AsyncStream<StreamingDelta>.Continuation) async {
        let settings = AISettings.load(keychainService: keychainService)
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
                var errorBytes: [UInt8] = []
                do {
                    for try await byte in bytes {
                        errorBytes.append(byte)
                    }
                } catch {
                    print("[AIProxy] Failed to read streaming error body: \(error)")
                }
                let errorData = Data(errorBytes)
                let apiError = Self.parseAPIError(data: errorData, statusCode: statusCode)
                print("[AIProxy] Streaming retry failed (\(statusCode)): \(apiError.localizedDescription)")
                continuation.yield(.error(apiError))
                continuation.finish()
                return
            }

            await processSSEStream(bytes: bytes, httpResponse: httpResponse, continuation: continuation)
        } catch {
            continuation.yield(.error(error))
            continuation.finish()
        }
    }

    /// 解析 SSE 流并 yield delta 事件，支持单次响应中包含多个 tool_calls。
    private func processSSEStream(
        bytes: URLSession.AsyncBytes,
        httpResponse: HTTPURLResponse,
        continuation: AsyncStream<StreamingDelta>.Continuation
    ) async {
        var toolCalls: [(id: String?, name: String?, args: String)] = []

        do {
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

                // Tool calls（按 index 累积，支持多个并行 tool call）
                if let toolCallsArray = delta["tool_calls"] as? [[String: Any]] {
                    for tc in toolCallsArray {
                        let index = tc["index"] as? Int ?? 0
                        // 确保数组长度足够容纳当前 index
                        while toolCalls.count <= index {
                            toolCalls.append((id: nil, name: nil, args: ""))
                        }
                        if let id = tc["id"] as? String {
                            toolCalls[index].id = id
                        }
                        if let function = tc["function"] as? [String: Any] {
                            if let name = function["name"] as? String {
                                toolCalls[index].name = name
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

    // MARK: - Retry for Connection Lost (-1005)

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
    ///   - profileOverride: 自愈重试时替换默认 provider profile。
    /// - Returns: 可直接用于 Chat Completions 的 `messages` 数组。
    private func buildOpenAIMessages(
        from history: [Message],
        serverContext: String,
        profileOverride: ProviderProfile? = nil
    ) -> [[String: Any]] {
        var openAIMessages: [[String: Any]] = []
        let settings = AISettings.load(keychainService: keychainService)
        let profile = profileOverride ?? resolveProfile(baseURL: settings.baseURL, modelName: settings.modelName)

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
                var assistantMessage: [String: Any] = [
                    "role": "assistant",
                    "content": msg.content,
                ]
                if profile.includeReasoningOnPlainAssistantMessages {
                    assistantMessage["reasoning_content"] = msg.reasoningContent ?? ""
                }
                openAIMessages.append(assistantMessage)
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
                    if profile.includeReasoningOnToolCallMessages {
                        assistantToolCallMessage["reasoning_content"] = msg.reasoningContent ?? ""
                    }
                    openAIMessages.append(assistantToolCallMessage)

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

    // MARK: - Error Parsing & Self-Healing

    /// 自愈方向：补 reasoning_content 还是去掉。
    private enum ReasoningHealingHint {
        case add, remove
    }

    /// 从 400 错误信息中判断是否可以通过翻转 reasoning_content 策略自愈。
    private static func reasoningHealingHint(from message: String) -> ReasoningHealingHint? {
        let lower = message.lowercased()
        if lower.contains("missing") && lower.contains("reasoning_content") {
            return .add
        }
        if lower.contains("reasoning_content") &&
            (lower.contains("not allowed") || lower.contains("invalid") || lower.contains("unexpected")) {
            return .remove
        }
        return nil
    }

    /// 从 API 错误响应中提取人类可读的错误信息。
    /// 优先尝试解析 `{ "error": { "message": "..." } }` 结构。
    private static func parseAPIError(data: Data, statusCode: Int) -> AIServiceError {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let errorObj = json["error"] as? [String: Any],
           let message = errorObj["message"] as? String {
            return .apiError(statusCode: statusCode, message: message)
        }
        let raw = String(data: data, encoding: .utf8) ?? "Unknown error"
        return .apiError(statusCode: statusCode, message: raw)
    }
}

// MARK: - AI Settings (stored in UserDefaults + Keychain)

/// AISettings：封装 AI 相关本地配置。
/// - API Key 存储于 Keychain（安全存储），其余配置存于 `UserDefaults`。
/// - 首次加载时自动将 UserDefaults 中的旧 API Key 迁移到 Keychain 并清除明文记录。
struct AISettings {
    var apiKey: String
    var baseURL: String
    var modelName: String
    var maxContextTokensK: Int  // Unit: K (e.g. 128 = 128,000 tokens)

    var maxContextTokens: Int { maxContextTokensK * 1000 }

    /// 供无参调用使用的共享 KeychainService 实例（兼容 SettingsView 等无法注入依赖的场景）。
    nonisolated(unsafe) static var sharedKeychainService: KeychainServiceProtocol = KeychainService()

    /// 从本地配置读取 AI 参数，API Key 从 Keychain 读取。
    /// - Parameter keychainService: Keychain 服务实例；为 `nil` 时使用共享实例。
    /// - Returns: 若未配置则返回包含默认值的设置对象。
    static func load(keychainService: KeychainServiceProtocol? = nil) -> AISettings {
        let keychain = keychainService ?? sharedKeychainService
        let defaults = UserDefaults.standard
        let storedK = defaults.integer(forKey: "aiMaxContextTokensK")

        // 迁移：若 UserDefaults 中存在旧 API Key，迁移至 Keychain 并清除明文
        var apiKey = ""
        if let legacyKey = defaults.string(forKey: "aiAPIKey"), !legacyKey.isEmpty {
            do {
                try keychain.saveAPIKey(legacyKey)
                defaults.removeObject(forKey: "aiAPIKey")
                apiKey = legacyKey
            } catch {
                print("[AISettings] Failed to migrate API key to Keychain: \(error)")
                apiKey = legacyKey
            }
        } else {
            apiKey = (try? keychain.getAPIKey()) ?? ""
        }

        return AISettings(
            apiKey: apiKey,
            baseURL: defaults.string(forKey: "aiBaseURL") ?? "",
            modelName: defaults.string(forKey: "aiModelName") ?? "gpt-4o",
            maxContextTokensK: storedK > 0 ? storedK : 128
        )
    }

    /// 将当前 AI 设置持久化：API Key 写入 Keychain，其余写入 `UserDefaults`。
    /// - Parameter keychainService: Keychain 服务实例；为 `nil` 时使用共享实例。
    /// - Side Effects: 覆盖同名键对应的历史配置值。
    func save(keychainService: KeychainServiceProtocol? = nil) {
        let keychain = keychainService ?? Self.sharedKeychainService
        let defaults = UserDefaults.standard

        // API Key 存入 Keychain；仅在成功后才清除 UserDefaults 中的明文记录
        do {
            if apiKey.isEmpty {
                try keychain.deleteAPIKey()
            } else {
                try keychain.saveAPIKey(apiKey)
            }
            // Keychain 写入成功，清除 UserDefaults 中可能残留的明文
            defaults.removeObject(forKey: "aiAPIKey")
        } catch {
            print("[AISettings] Failed to save API key to Keychain: \(error)")
            // Keychain 写失败时保留 UserDefaults 作为兜底，避免数据丢失
        }

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
