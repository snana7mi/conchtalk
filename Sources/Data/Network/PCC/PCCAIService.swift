/// 文件说明：PCCAIService，基于 Apple Foundation Models（Private Cloud Compute 服务器模型）的 AI 服务实现。
import Foundation
import FoundationModels

/// PCCAIService：
/// 使用 `PrivateCloudComputeLanguageModel` + `LanguageModelSession` 实现 `AIServiceProtocol`。
/// - 历史消息沿用 `MessageBuilder` 的 OpenAI 格式，再映射为 `Transcript`，与自有端点语义一致。
/// - 工具只声明不执行：模型调用工具时会话被中断，调用以 `.toolCall` 交回上层，
///   由现有审批（SSH 确认）与执行流程处理，结果写入历史后经 `sendToolResultStreaming` 继续。
/// - PCC 不可用 / 额度用尽 / 网络或服务失败时产出 `PCCServiceError`，由 `RoutingAIService` 决定是否回退。
@available(iOS 27.0, macOS 27.0, *)
nonisolated final class PCCAIService: AIServiceProtocol, ToolScopableAIService, @unchecked Sendable {
    /// 工具结果回填后用于驱动下一轮回复的提示（Foundation Models 每轮需要一个新的 prompt）。
    static let toolContinuationPrompt = "[System: The tool results are above. Continue the task.]"

    private let toolRegistry: ToolRegistryProtocol
    private let skillRegistry: any SkillLookingUp
    private let trustedInstructions: String?
    private let model: PrivateCloudComputeLanguageModel
    private let defaults: UserDefaults

    init(
        toolRegistry: ToolRegistryProtocol,
        skillRegistry: any SkillLookingUp,
        trustedInstructions: String? = nil,
        model: PrivateCloudComputeLanguageModel = PrivateCloudComputeLanguageModel(),
        defaults: UserDefaults = .standard
    ) {
        self.toolRegistry = toolRegistry
        self.skillRegistry = skillRegistry
        self.trustedInstructions = trustedInstructions
        self.model = model
        self.defaults = defaults
    }

    func withToolRegistry(_ toolRegistry: ToolRegistryProtocol, trustedInstructions: String?) -> PCCAIService {
        PCCAIService(
            toolRegistry: toolRegistry,
            skillRegistry: skillRegistry,
            trustedInstructions: trustedInstructions,
            model: model,
            defaults: defaults
        )
    }

    // MARK: - Availability

    /// 当前不可用原因；可用时为 nil。
    var unavailableFailure: PCCFailure? {
        switch model.availability {
        case .available:
            return nil
        case .unavailable(let reason):
            return Self.failure(for: reason)
        }
    }

    static func failure(for reason: PrivateCloudComputeLanguageModel.Availability.UnavailableReason) -> PCCFailure {
        switch reason {
        case .deviceNotEligible: return .deviceNotEligible
        case .systemNotReady: return .systemNotReady
        @unknown default: return .systemNotReady
        }
    }

    /// 把 Foundation Models 的 PCC 错误映射为 `PCCFailure`；其他错误（如安全拦截、上下文超限）返回 nil。
    static func failure(from error: Error) -> PCCFailure? {
        guard let pccError = error as? PrivateCloudComputeLanguageModel.Error else { return nil }
        switch pccError {
        case .quotaLimitReached(let info): return .quotaLimitReached(resetDate: info.resetDate)
        case .networkFailure: return .networkFailure
        case .serviceUnavailable: return .serviceUnavailable
        @unknown default: return .serviceUnavailable
        }
    }

    /// 用户思考力度 → PCC 推理级别；「模型默认」不指定。
    static func reasoningLevel(for level: AIThinkingLevel) -> ContextOptions.ReasoningLevel? {
        switch level {
        case .modelDefault: return nil
        case .low: return .light
        case .medium: return .moderate
        case .high: return .deep
        }
    }

    // MARK: - Streaming API

    func sendMessageStreaming(_ message: String, conversationHistory: [Message], serverContext: String, serverID: UUID?, permissionLevel: PermissionLevel, serverName: String, serverCapabilities: ServerCapabilities) -> AsyncStream<StreamingDelta> {
        makeStream(
            prompt: message,
            history: conversationHistory,
            serverContext: serverContext,
            permissionLevel: permissionLevel,
            serverName: serverName,
            serverCapabilities: serverCapabilities
        )
    }

    // 与 UserAIService 一致：工具结果已由调用方写入 `conversationHistory`（`.command` 消息）。
    func sendToolResultStreaming(_ result: String, forToolCall: ToolCall, conversationHistory: [Message], serverContext: String, serverID: UUID?, permissionLevel: PermissionLevel, serverName: String, serverCapabilities: ServerCapabilities) -> AsyncStream<StreamingDelta> {
        makeStream(
            prompt: Self.toolContinuationPrompt,
            history: conversationHistory,
            serverContext: serverContext,
            permissionLevel: permissionLevel,
            serverName: serverName,
            serverCapabilities: serverCapabilities
        )
    }

    func estimateRequestOverheadTokens(serverContext: String, permissionLevel: PermissionLevel, serverName: String, serverCapabilities: ServerCapabilities) -> Int {
        let estimator = TokenEstimator()
        var tokens = estimator.estimateTokens(systemPrompt(serverContext: serverContext, permissionLevel: permissionLevel, serverName: serverName))
        let definitions = toolRegistry.openAIToolDefinitions(capabilities: serverCapabilities)
        if let data = try? JSONSerialization.data(withJSONObject: definitions),
           let json = String(data: data, encoding: .utf8) {
            tokens += estimator.estimateTokens(json)
        }
        return tokens
    }

    private func systemPrompt(serverContext: String, permissionLevel: PermissionLevel, serverName: String) -> String {
        SystemPromptBuilder.build(
            serverName: serverName,
            serverContext: serverContext,
            tools: toolRegistry.tools,
            permissionLevel: permissionLevel,
            skillSummaries: skillRegistry.skillSummaries,
            trustedInstructions: trustedInstructions
        )
    }

    private func makeStream(
        prompt: String,
        history: [Message],
        serverContext: String,
        permissionLevel: PermissionLevel,
        serverName: String,
        serverCapabilities: ServerCapabilities
    ) -> AsyncStream<StreamingDelta> {
        AsyncStream { continuation in
            let task = Task {
                await self.run(
                    prompt: prompt,
                    history: history,
                    serverContext: serverContext,
                    permissionLevel: permissionLevel,
                    serverName: serverName,
                    serverCapabilities: serverCapabilities,
                    continuation: continuation
                )
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(
        prompt: String,
        history: [Message],
        serverContext: String,
        permissionLevel: PermissionLevel,
        serverName: String,
        serverCapabilities: ServerCapabilities,
        continuation: AsyncStream<StreamingDelta>.Continuation
    ) async {
        if let failure = unavailableFailure {
            continuation.yield(.error(PCCServiceError(failure: failure)))
            return
        }
        await refreshContextSizeCache()

        let tools = PCCToolProxy.proxies(
            fromOpenAIDefinitions: toolRegistry.openAIToolDefinitions(capabilities: serverCapabilities)
        )
        let messages = MessageBuilder.build(
            from: history,
            options: MessageBuilderOptions(
                includeReasoningOnToolCallMessages: false,
                includeReasoningOnPlainAssistantMessages: false,
                includeAnthropicThinkingBlocks: false
            )
        )
        let entries = PCCTranscriptMapper.transcriptEntries(
            instructions: systemPrompt(serverContext: serverContext, permissionLevel: permissionLevel, serverName: serverName),
            toolDefinitions: tools.map { Transcript.ToolDefinition(tool: $0) },
            messages: messages
        )
        let session = LanguageModelSession(model: model, tools: tools, transcript: Transcript(entries: entries))
        let thinking = AIThinkingLevel(rawValue: defaults.string(forKey: "aiThinkingLevel") ?? "") ?? .modelDefault
        let stream = session.streamResponse(
            to: Prompt(prompt),
            options: GenerationOptions(),
            contextOptions: ContextOptions(reasoningLevel: Self.reasoningLevel(for: thinking))
        )

        var emittedText = ""
        var emittedReasoning = ""
        var lastUsage: LanguageModelSession.Usage?
        do {
            for try await snapshot in stream {
                let reasoning = PCCTranscriptMapper.reasoningText(in: snapshot.transcriptEntries)
                if let delta = PCCStreamDiff.delta(previous: emittedReasoning, current: reasoning) {
                    continuation.yield(.reasoning(delta))
                    emittedReasoning = reasoning
                }
                let text = snapshot.content
                if let delta = PCCStreamDiff.delta(previous: emittedText, current: text) {
                    continuation.yield(.content(delta))
                    emittedText = text
                }
                lastUsage = snapshot.usage
            }
            yieldUsage(lastUsage, into: continuation)
            continuation.yield(.done)
        } catch let error as LanguageModelSession.ToolCallError where error.underlyingError is PCCToolInterception {
            // 模型请求调用工具：从 transcript 取出本轮全部调用，交回上层执行。
            let calls = PCCTranscriptMapper.lastToolCalls(in: session.transcript)
            let responseID = UUID().uuidString
            for call in PCCTranscriptMapper.toolCalls(from: calls, responseID: responseID) {
                continuation.yield(.toolCall(call))
            }
            yieldUsage(lastUsage, into: continuation)
            continuation.yield(.done)
        } catch is CancellationError {
            return
        } catch {
            if let failure = Self.failure(from: error) {
                continuation.yield(.error(PCCServiceError(failure: failure)))
            } else {
                continuation.yield(.error(error))
            }
        }
    }

    private func yieldUsage(_ usage: LanguageModelSession.Usage?, into continuation: AsyncStream<StreamingDelta>.Continuation) {
        guard let usage else { return }
        continuation.yield(.usage(StreamingTokenUsage(
            inputTokens: usage.input.totalTokenCount,
            outputTokens: usage.output.totalTokenCount,
            cacheReadInputTokens: usage.input.cachedTokenCount
        )))
    }

    /// 读取系统报告的 PCC 上下文窗口并缓存，供压缩预算使用。
    private func refreshContextSizeCache() async {
        if let size = try? await model.contextSize {
            AIProviderSettings.storePCCContextSize(size, defaults: defaults)
        }
    }

    // MARK: - Non-streaming

    func sendSimpleMessage(_ prompt: String) async throws -> String {
        try await respond(entries: [], prompt: prompt, instructions: nil)
    }

    func generateMemorySummary(recentMessages: [Message], existingConversationMemory: String?, existingServerMemory: String?, existingGlobalMemory: String?) async throws -> MemorySummaryResult {
        let messages = AIAuxiliaryService.buildMemorySummaryMessages(
            recentMessages: recentMessages,
            existingConversationMemory: existingConversationMemory,
            existingServerMemory: existingServerMemory,
            existingGlobalMemory: existingGlobalMemory
        )
        let instructions = messages
            .filter { ($0["role"] as? String) == "system" }
            .compactMap { $0["content"] as? String }
            .joined(separator: "\n\n")
        let conversation = messages.filter { ($0["role"] as? String) != "system" }
        let prompt = conversation.last?["content"] as? String ?? "Extract memories from this conversation."
        let content = try await respond(
            entries: PCCTranscriptMapper.historyEntries(from: Array(conversation.dropLast())),
            prompt: prompt,
            instructions: instructions
        )
        return AIAuxiliaryService.parseMemorySummary(from: content)
    }

    private func respond(entries: [Transcript.Entry], prompt: String, instructions: String?) async throws -> String {
        if let failure = unavailableFailure { throw PCCServiceError(failure: failure) }
        var transcriptEntries: [Transcript.Entry] = []
        if let instructions {
            transcriptEntries.append(.instructions(Transcript.Instructions(
                segments: [.text(Transcript.TextSegment(content: instructions))],
                toolDefinitions: []
            )))
        }
        transcriptEntries.append(contentsOf: entries)
        let session = LanguageModelSession(model: model, transcript: Transcript(entries: transcriptEntries))
        do {
            return try await session.respond(to: Prompt(prompt), options: GenerationOptions(temperature: 0.3)).content
        } catch {
            if let failure = Self.failure(from: error) { throw PCCServiceError(failure: failure) }
            throw error
        }
    }
}

/// PCCStreamDiff：Foundation Models 流产出累计快照，这里换算为增量。
nonisolated enum PCCStreamDiff {
    /// 返回 `current` 相对 `previous` 的新增部分；无新增或内容被改写（非前缀扩展）时返回 nil。
    static func delta(previous: String, current: String) -> String? {
        guard current.count > previous.count, current.hasPrefix(previous) else { return nil }
        return String(current.dropFirst(previous.count))
    }
}
