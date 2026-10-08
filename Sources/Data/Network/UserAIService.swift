/// 文件说明：UserAIService，负责用户自有 AI 路线的请求编排、流式事件解析、重试与上下文压缩。
import Foundation

/// UserAIService：
/// `AIServiceProtocol` 的基础设施实现，统一处理消息协议转换、压缩决策、
/// 流式调用与连接丢失重试，向上层提供稳定的 AI 调用语义。
nonisolated final class UserAIService: AIServiceProtocol, @unchecked Sendable {
    private let session: URLSession
    private let keychainService: KeychainServiceProtocol
    private let toolRegistry: ToolRegistryProtocol
    private let skillRegistry: SkillRegistry
    /// App 内置的可信角色说明，仅供受限 subagent 使用。
    private let trustedInstructions: String?
    private let streamingExecutor: StreamingExecutor
    private let auxiliaryService: AIAuxiliaryService

    /// 初始化 AI 服务客户端。
    /// - Parameters:
    ///   - keychainService: 凭据服务，用于安全存储和读取 API Key。
    ///   - toolRegistry: 工具注册表，用于注入 `tools` 定义与系统提示词。
    /// - Side Effects: 创建带 120 秒请求超时的 `URLSession`。
    init(
        keychainService: KeychainServiceProtocol,
        toolRegistry: ToolRegistryProtocol,
        skillRegistry: SkillRegistry,
        trustedInstructions: String? = nil
    ) {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        let urlSession = URLSession(configuration: config)
        self.session = urlSession
        self.keychainService = keychainService
        self.toolRegistry = toolRegistry
        self.skillRegistry = skillRegistry
        self.trustedInstructions = trustedInstructions
        self.streamingExecutor = StreamingExecutor(session: urlSession)
        self.auxiliaryService = AIAuxiliaryService(session: urlSession)
    }

    /// 创建一个共享相同用户 API 配置、但使用不同工具定义的 AI 服务视图。
    /// 子 agent 使用受限工具表时需要同时限制「模型可见 schema」与「执行侧 registry」。
    func withToolRegistry(
        _ toolRegistry: ToolRegistryProtocol,
        trustedInstructions: String? = nil
    ) -> UserAIService {
        UserAIService(
            keychainService: keychainService,
            toolRegistry: toolRegistry,
            skillRegistry: skillRegistry,
            trustedInstructions: trustedInstructions
        )
    }

    /// 使用用户在本机配置的 API 端点构建请求，不引入额外转发层。
    private func resolveRequestConfig() async throws -> AIRequestConfig {
        let settings = AISettings.load(keychainService: keychainService)

        guard !settings.apiKey.isEmpty else { throw AIServiceError.apiKeyMissing }
        guard !settings.endpointURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIServiceError.endpointMissing
        }
        guard !settings.modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIServiceError.modelMissing
        }
        let endpointURL = Self.normalizeEndpointURL(settings.endpointURL, format: settings.apiFormat)
        return AIRequestConfig(
            endpointURL: endpointURL,
            apiKey: settings.apiKey,
            modelName: settings.modelName,
            strategy: settings.apiFormat == .anthropic
                ? AnthropicFormatStrategy(
                    automaticPromptCaching: AnthropicFormatStrategy.supportsAutomaticPromptCaching(endpointURL: endpointURL),
                    maxOutputTokens: settings.resolvedMaxOutputTokens(),
                    thinkingLevel: settings.thinkingLevel
                )
                : OpenAIFormatStrategy(reasoningEffort: settings.thinkingLevel.effortValue)
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

    /// 按实际发送的 system prompt 与工具定义估算固定请求开销。
    func estimateRequestOverheadTokens(
        serverContext: String,
        permissionLevel: PermissionLevel,
        serverName: String,
        serverCapabilities: ServerCapabilities
    ) -> Int {
        let estimator = TokenEstimator()
        let systemPrompt = SystemPromptBuilder.build(
            serverName: serverName,
            serverContext: serverContext,
            tools: toolRegistry.tools,
            permissionLevel: permissionLevel,
            skillSummaries: skillRegistry.skillSummaries,
            trustedInstructions: trustedInstructions
        )
        var tokens = estimator.estimateTokens(systemPrompt)

        let definitions = toolRegistry.openAIToolDefinitions(capabilities: serverCapabilities)
        if let data = try? JSONSerialization.data(withJSONObject: definitions),
           let json = String(data: data, encoding: .utf8) {
            tokens += estimator.estimateTokens(json)
        }
        return tokens
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
                        toolDefinitions: toolDefinitions
                    )
                    switch healResult {
                    case .needsRetry(let hint):
                        let freshConfig = try await resolveRequestConfig()
                        let healProfile: ProviderProfile = (hint == .add) ? DeepSeekProfile() : NoReasoningProfile()
                        await streamingExecutor.executeDirect(
                            messages: retryMessages(healProfile),
                            config: freshConfig,
                            toolDefinitions: toolDefinitions,
                            continuation: continuation
                        )
                    case .stream(let bytes, _):
                        await config.strategy.processSSEStream(bytes: bytes, continuation: continuation)
                    case .error(let error):
                        // 用户开启的思考参数被端点拒绝：切换 / 去掉该参数后重试一次
                        if let fallbackStrategy = Self.thinkingFallbackStrategy(for: error, strategy: config.strategy) {
                            let retryConfig = AIRequestConfig(
                                endpointURL: config.endpointURL,
                                apiKey: config.apiKey,
                                modelName: config.modelName,
                                strategy: fallbackStrategy
                            )
                            await streamingExecutor.executeDirect(
                                messages: messages,
                                config: retryConfig,
                                toolDefinitions: toolDefinitions,
                                continuation: continuation
                            )
                        } else {
                            continuation.yield(.error(error))
                            continuation.finish()
                        }
                    }
                } catch {
                    continuation.yield(.error(error))
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// 400 自愈：思考配置与模型不匹配时返回调整后的策略。
    /// - Anthropic：adaptive ↔ manual（"adaptive thinking is not supported" / "thinking.type.enabled is not supported"）。
    /// - OpenAI 兼容：端点不认 `reasoning_effort` 时去掉该参数。
    static func thinkingFallbackStrategy(for error: Error, strategy: APIFormatStrategy) -> APIFormatStrategy? {
        guard case AIServiceError.apiError(let status, let message)? = error as? AIServiceError, status == 400 else {
            return nil
        }
        if let anthropic = strategy as? AnthropicFormatStrategy,
           anthropic.thinkingLevel != .modelDefault,
           let mode = AnthropicModelCapabilities.thinkingModeFallback(from: message),
           mode != anthropic.thinkingModeOverride {
            print("[AIProxy] Thinking mode rejected, retrying with \(mode.rawValue) thinking")
            return anthropic.withThinkingMode(mode)
        }
        if let openAI = strategy as? OpenAIFormatStrategy,
           openAI.reasoningEffort != nil,
           message.lowercased().contains("reasoning_effort") {
            print("[AIProxy] reasoning_effort rejected, retrying without it")
            return openAI.withoutReasoningEffort()
        }
        return nil
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
                skillSummaries: skillRegistry.skillSummaries,
                trustedInstructions: trustedInstructions
            ),
        ])

        // 历史消息转换委托给 MessageBuilder
        let options = MessageBuilderOptions(
            includeReasoningOnToolCallMessages: profile.includeReasoningOnToolCallMessages,
            includeReasoningOnPlainAssistantMessages: profile.includeReasoningOnPlainAssistantMessages,
            includeAnthropicThinkingBlocks: profile.includeAnthropicThinkingBlocks
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
            let lower = trimmed.lowercased()
            if lower.hasSuffix("/messages") || lower.hasSuffix("/v1/messages") { return trimmed }
            let base = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if base.lowercased().hasSuffix("/v1") {
                return base + "/messages"
            }
            return base + "/v1/messages"
        case .openAI:
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
    case endpointMissing
    case modelMissing
    case invalidResponse
    case apiError(statusCode: Int, message: String)

    /// 适用于界面展示的错误文案。
    var errorDescription: String? {
        switch self {
        case .apiKeyMissing:
            return String(
                localized: "API Key not configured. Go to Settings to add your own API key.",
                bundle: LanguageSettings.currentBundle
            )
        case .endpointMissing:
            return String(
                localized: "AI endpoint not configured. Go to Settings to add your own endpoint.",
                bundle: LanguageSettings.currentBundle
            )
        case .modelMissing:
            return String(
                localized: "Model not configured. Go to Settings to choose a model.",
                bundle: LanguageSettings.currentBundle
            )
        case .invalidResponse:
            return String(
                localized: "Invalid response from AI service",
                bundle: LanguageSettings.currentBundle
            )
        case .apiError(let code, let message):
            let format = String(
                localized: "AI API error (%lld): %@",
                bundle: LanguageSettings.currentBundle
            )
            return String(
                format: format,
                locale: LanguageSettings.currentLocale,
                Int64(code),
                message
            )
        }
    }
}
