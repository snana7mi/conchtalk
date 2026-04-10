/// 文件说明：AIProxyService，负责 AI 请求编排、流式事件解析、重试与上下文压缩。
import Foundation

/// AIProxyService：
/// `AIServiceProtocol` 的基础设施实现，统一处理消息协议转换、压缩决策、
/// 流式调用与连接丢失重试，向上层提供稳定的 AI 调用语义。
nonisolated final class AIProxyService: AIServiceProtocol, @unchecked Sendable {
    private let session: URLSession
    private let keychainService: KeychainServiceProtocol
    private let toolRegistry: ToolRegistryProtocol
    private let skillRegistry: SkillRegistry
    private let authService: AuthServiceProtocol?
    private let streamingExecutor: StreamingExecutor
    private let auxiliaryService: AIAuxiliaryService

    /// 初始化 AI 服务客户端。
    /// - Parameters:
    ///   - keychainService: 凭据服务，用于安全存储和读取 API Key。
    ///   - toolRegistry: 工具注册表，用于注入 `tools` 定义与系统提示词。
    ///   - authService: 认证服务，用于云端代理模式获取 JWT；为 nil 时仅支持本地配置模式。
    /// - Side Effects: 创建带 120 秒请求超时的 `URLSession`。
    init(keychainService: KeychainServiceProtocol, toolRegistry: ToolRegistryProtocol, skillRegistry: SkillRegistry, authService: AuthServiceProtocol? = nil) {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        let urlSession = URLSession(configuration: config)
        self.session = urlSession
        self.keychainService = keychainService
        self.toolRegistry = toolRegistry
        self.skillRegistry = skillRegistry
        self.authService = authService
        self.streamingExecutor = StreamingExecutor(session: urlSession)
        self.auxiliaryService = AIAuxiliaryService(session: urlSession)
    }

    /// 根据 useLocalConfig 路由到本地直连或云端代理。
    private func resolveRequestConfig() async throws -> AIRequestConfig {
        let settings = AISettings.load(keychainService: keychainService)

        if settings.useLocalConfig {
            // 本地配置：用户填的 URL、Key、格式
            guard !settings.apiKey.isEmpty else { throw AIServiceError.apiKeyMissing }
            let endpointURL = Self.normalizeEndpointURL(settings.endpointURL, format: settings.apiFormat)
            return AIRequestConfig(
                endpointURL: endpointURL,
                apiKey: settings.apiKey,
                modelName: settings.modelName.isEmpty ? "gpt-4o" : settings.modelName,
                strategy: settings.apiFormat == .anthropic
                    ? AnthropicFormatStrategy() : OpenAIFormatStrategy()
            )
        }

        // 云端代理模式
        guard let authService else {
            throw AIServiceError.apiKeyMissing  // AuthService not available
        }
        let token = try await authService.validAccessToken()
        return AIRequestConfig(
            endpointURL: "https://api.conch-talk.com/api/conchtalk",
            apiKey: token,
            modelName: "",  // 模型名由后端决定
            strategy: OpenAIFormatStrategy()  // 后端代理始终走 OpenAI 格式
        )
    }


    // MARK: - Streaming API

    /// 流式发送用户消息并持续产出 `StreamingDelta`。
    /// - Returns: 不抛错的 `AsyncStream`；错误通过 `.error` 事件传递。
    func sendMessageStreaming(_ message: String, conversationHistory: [Message], serverContext: String, serverID: UUID? = nil, permissionLevel: PermissionLevel = .standard, serverName: String = "AI Assistant", serverCapabilities: ServerCapabilities = .unknown) -> AsyncStream<StreamingDelta> {
        makeStreamingRequest(serverCapabilities: serverCapabilities) { [self] in
            var messages = self.buildOpenAIMessages(
                from: conversationHistory,
                serverContext: serverContext,
                permissionLevel: permissionLevel,
                serverID: serverID,
                serverName: serverName
            )
            messages.append(["role": "user", "content": message])
            return messages
        } retryMessages: { [self] profile in
            var messages = self.buildOpenAIMessages(
                from: conversationHistory,
                serverContext: serverContext,
                profileOverride: profile,
                permissionLevel: permissionLevel,
                serverID: serverID,
                serverName: serverName
            )
            messages.append(["role": "user", "content": message])
            return messages
        }
    }

    // Note: `result` and `toolCall` are not directly used here — the tool result is already
    // embedded in `conversationHistory` (as a `.command` message with `toolCall` + `toolOutput`)
    // by the caller (`ExecuteNaturalLanguageCommandUseCase`) before invoking this method.
    // These parameters are retained for protocol conformance and potential future use.
    func sendToolResultStreaming(_ result: String, forToolCall toolCall: ToolCall, conversationHistory: [Message], serverContext: String, serverID: UUID? = nil, permissionLevel: PermissionLevel = .standard, serverName: String = "AI Assistant", serverCapabilities: ServerCapabilities = .unknown) -> AsyncStream<StreamingDelta> {
        makeStreamingRequest(serverCapabilities: serverCapabilities) { [self] in
            self.buildOpenAIMessages(
                from: conversationHistory,
                serverContext: serverContext,
                permissionLevel: permissionLevel,
                serverID: serverID,
                serverName: serverName
            )
        } retryMessages: { [self] profile in
            self.buildOpenAIMessages(
                from: conversationHistory,
                serverContext: serverContext,
                profileOverride: profile,
                permissionLevel: permissionLevel,
                serverID: serverID,
                serverName: serverName
            )
        }
    }

    /// 统一处理流式请求、自愈重试和错误回填。
    private func makeStreamingRequest(
        serverCapabilities: ServerCapabilities,
        initialMessages: @escaping @Sendable () -> [[String: Any]],
        retryMessages: @escaping @Sendable (ProviderProfile) -> [[String: Any]]
    ) -> AsyncStream<StreamingDelta> {
        AsyncStream { continuation in
            let task = Task {
                do {
                    let config = try await resolveRequestConfig()
                    let messages = initialMessages()
                    let toolDefinitions = toolRegistry.openAIToolDefinitions(capabilities: serverCapabilities)

                    let healResult = await streamingExecutor.executeWithHealing(
                        messages: messages,
                        config: config,
                        toolDefinitions: toolDefinitions,
                        authService: authService,
                        resolveNewConfig: { [self] in try await self.resolveRequestConfig() }
                    )
                    switch healResult {
                    case .needsRetry(let hint):
                        let freshConfig = try await resolveRequestConfig()
                        let healProfile: ProviderProfile = (hint == .add) ? DeepSeekProfile() : DefaultProfile()
                        await streamingExecutor.executeDirect(
                            messages: retryMessages(healProfile),
                            config: freshConfig,
                            toolDefinitions: toolDefinitions,
                            continuation: continuation
                        )
                    case .stream(let bytes, _):
                        await config.strategy.processSSEStream(bytes: bytes, continuation: continuation)
                    case .error(let error):
                        continuation.yield(.error(error))
                        continuation.finish()
                    }
                } catch {
                    continuation.yield(.error(error))
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Message Conversion

    /// 将应用内消息模型转换为 OpenAI 协议消息数组。
    /// - Parameters:
    ///   - history: 会话历史消息。
    ///   - serverContext: 服务器上下文信息。
    ///   - profileOverride: 自愈重试时替换默认 provider profile。
    ///   - permissionLevel: 当前生效的操作权限等级。
    ///   - serverID: 服务器 ID，用于查找激活的 Skill。
    /// - Returns: 可直接用于 Chat Completions 的 `messages` 数组。
    private func buildOpenAIMessages(
        from history: [Message],
        serverContext: String,
        profileOverride: ProviderProfile? = nil,
        permissionLevel: PermissionLevel = .standard,
        serverID: UUID? = nil,
        serverName: String = "AI Assistant"
    ) -> [[String: Any]] {
        var openAIMessages: [[String: Any]] = []
        let settings = AISettings.load(keychainService: keychainService)
        let profile = profileOverride ?? resolveProfile(endpointURL: settings.endpointURL, modelName: settings.modelName)

        // System prompt
        openAIMessages.append([
            "role": "system",
            "content": SystemPromptBuilder.build(
                serverName: serverName,
                serverContext: serverContext,
                tools: toolRegistry.tools,
                permissionLevel: permissionLevel,
                skillSummaries: skillRegistry.skillSummaries
            ),
        ])

        // 历史消息转换委托给 MessageBuilder
        let options = MessageBuilderOptions(
            includeReasoningOnToolCallMessages: profile.includeReasoningOnToolCallMessages,
            includeReasoningOnPlainAssistantMessages: profile.includeReasoningOnPlainAssistantMessages
        )
        let historyMessages = MessageBuilder.build(from: history, options: options)
        openAIMessages.append(contentsOf: historyMessages)

        return openAIMessages
    }

    // MARK: - Memory Summary Generation

    /// 使用轻量级非流式请求，从最近消息中提取三层记忆总结。
    func generateMemorySummary(
        recentMessages: [Message],
        existingConversationMemory: String?,
        existingServerMemory: String?,
        existingGlobalMemory: String?
    ) async throws -> MemorySummaryResult {
        let config = try await resolveRequestConfig()
        return try await auxiliaryService.generateMemorySummary(
            recentMessages: recentMessages,
            existingConversationMemory: existingConversationMemory,
            existingServerMemory: existingServerMemory,
            existingGlobalMemory: existingGlobalMemory,
            config: config
        )
    }

    // MARK: - Simple Message

    /// 发送简单的非流式 AI 请求，返回文本回复。
    /// 适用于记忆提取、简单摘要等不需要流式输出的场景。
    func sendSimpleMessage(_ prompt: String) async throws -> String {
        let config = try await resolveRequestConfig()
        guard let url = URL(string: config.endpointURL) else {
            throw AIServiceError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        config.strategy.setAuthHeaders(on: &request, apiKey: config.apiKey)
        request.timeoutInterval = 60
        let messages: [[String: Any]] = [["role": "user", "content": prompt]]
        request.httpBody = try config.strategy.buildNonStreamingRequestBody(
            messages: messages,
            model: config.modelName,
            maxTokens: 1000,
            temperature: 0.3,
            reasoningEffort: "none"
        )
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw config.strategy.parseError(data: data, statusCode: statusCode)
        }
        return try config.strategy.parseNonStreamingContent(from: data)
    }

    // MARK: - URL Normalization

    /// 规范化端点 URL：若用户输入了 base URL（如 `https://api.openai.com/v1`），
    /// 自动补全对应格式的 path（`/chat/completions` 或 `/messages`）。
    private static func normalizeEndpointURL(_ url: String, format: APIFormat) -> String {
        let trimmed = url.trimmingCharacters(in: .whitespaces)
        switch format {
        case .anthropic:
            let defaultURL = "https://api.anthropic.com/v1/messages"
            if trimmed.isEmpty { return defaultURL }
            let lower = trimmed.lowercased()
            if lower.hasSuffix("/messages") || lower.hasSuffix("/v1/messages") { return trimmed }
            let base = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if base.lowercased().hasSuffix("/v1") {
                return base + "/messages"
            }
            return base + "/v1/messages"
        case .openAI:
            let defaultURL = "https://api.openai.com/v1/chat/completions"
            if trimmed.isEmpty { return defaultURL }
            let lower = trimmed.lowercased()
            if lower.hasSuffix("/chat/completions") || lower.hasSuffix("/completions") { return trimmed }
            return trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/chat/completions"
        }
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
