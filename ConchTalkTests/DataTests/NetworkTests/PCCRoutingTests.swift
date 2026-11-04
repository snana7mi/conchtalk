/// 文件说明：PCCRoutingTests，验证 AI 服务来源设置、PCC 回退策略与 RoutingAIService 路由/回退行为。
import Testing
@testable import ConchTalk
import Foundation

// MARK: - 测试替身

/// 可配置流式输出的最小 AI 服务替身（支持工具表收窄）。
private final class StubAIService: ToolScopableAIService, @unchecked Sendable {
    let deltas: [StreamingDelta]
    var simpleResult: Result<String, Error>
    private(set) var streamCalls = 0
    private(set) var simpleCalls = 0

    init(deltas: [StreamingDelta], simpleResult: Result<String, Error> = .success("ok")) {
        self.deltas = deltas
        self.simpleResult = simpleResult
    }

    func withToolRegistry(_ toolRegistry: ToolRegistryProtocol, trustedInstructions: String?) -> StubAIService { self }

    private func stream() -> AsyncStream<StreamingDelta> {
        streamCalls += 1
        let deltas = deltas
        return AsyncStream { continuation in
            for delta in deltas { continuation.yield(delta) }
            continuation.finish()
        }
    }

    func sendMessageStreaming(_ message: String, conversationHistory: [Message], serverContext: String, serverID: UUID?, permissionLevel: PermissionLevel, serverName: String, serverCapabilities: ServerCapabilities) -> AsyncStream<StreamingDelta> { stream() }

    func sendToolResultStreaming(_ result: String, forToolCall: ToolCall, conversationHistory: [Message], serverContext: String, serverID: UUID?, permissionLevel: PermissionLevel, serverName: String, serverCapabilities: ServerCapabilities) -> AsyncStream<StreamingDelta> { stream() }

    func generateMemorySummary(recentMessages: [Message], existingConversationMemory: String?, existingServerMemory: String?, existingGlobalMemory: String?) async throws -> MemorySummaryResult {
        MemorySummaryResult(conversationMemory: nil, serverMemory: nil, globalMemory: nil)
    }

    func sendSimpleMessage(_ prompt: String) async throws -> String {
        simpleCalls += 1
        return try simpleResult.get()
    }

    func estimateRequestOverheadTokens(serverContext: String, permissionLevel: PermissionLevel, serverName: String, serverCapabilities: ServerCapabilities) -> Int { 0 }
}

private func collectContent(_ stream: AsyncStream<StreamingDelta>) async -> (content: String, errors: [Error]) {
    var content = ""
    var errors: [Error] = []
    for await delta in stream {
        switch delta {
        case .content(let text): content += text
        case .error(let error): errors.append(error)
        default: break
        }
    }
    return (content, errors)
}

private func send(_ service: RoutingAIService) -> AsyncStream<StreamingDelta> {
    service.sendMessageStreaming("hi", conversationHistory: [], serverContext: "", serverID: nil, permissionLevel: .standard, serverName: "s", serverCapabilities: .unknown)
}

// MARK: - 设置

@Suite("AIProviderSettings")
struct AIProviderSettingsTests {
    private func makeDefaults() -> UserDefaults {
        let name = "PCCRoutingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test("缺省为自有端点，保存后可读回")
    func roundTrip() {
        let defaults = makeDefaults()
        #expect(AIProviderSettings.load(defaults: defaults) == .customEndpoint)
        AIProviderSettings.save(.applePrivateCloudCompute, defaults: defaults)
        #expect(AIProviderSettings.load(defaults: defaults) == .applePrivateCloudCompute)
    }

    @Test("PCC 上下文预算 = 窗口 - 输出预留，且有下限")
    func contextBudget() {
        #expect(AIProviderSettings.pccContextBudget(contextSize: 32_768) == 32_768 - AIProviderSettings.pccOutputReserve)
        #expect(AIProviderSettings.pccContextBudget(contextSize: 1_000) == 4_000)
    }

    @Test("选用 PCC 时压缩预算使用缓存的 PCC 窗口")
    func maxContextTokensUsesPCCWindow() {
        let defaults = makeDefaults()
        defaults.set(128, forKey: "aiMaxContextTokensK")
        #expect(AISettings.loadMaxContextTokens(defaults: defaults) == 128_000)

        AIProviderSettings.save(.applePrivateCloudCompute, defaults: defaults)
        AIProviderSettings.storePCCContextSize(20_000, defaults: defaults)
        if #available(iOS 27.0, macOS 27.0, *) {
            #expect(AISettings.loadMaxContextTokens(defaults: defaults) == 20_000 - AIProviderSettings.pccOutputReserve)
        } else {
            #expect(AISettings.loadMaxContextTokens(defaults: defaults) == 128_000)
        }
    }

    @Test("自有端点三要素齐全才视为已配置")
    func customEndpointConfigured() {
        var settings = AISettings(apiKey: "k", endpointURL: "https://x", modelName: "m", maxContextTokensK: 128, apiFormat: .openAI, permissionLevel: .standard)
        #expect(settings.hasCustomEndpointConfigured)
        settings.modelName = "  "
        #expect(!settings.hasCustomEndpointConfigured)
    }
}

// MARK: - 回退策略

@Suite("PCCFallbackPolicy")
struct PCCFallbackPolicyTests {
    @Test("PCC 错误在未输出前且已配置自有端点时回退")
    func fallsBack() {
        let error = PCCServiceError(failure: .quotaLimitReached(resetDate: nil))
        #expect(PCCFallbackPolicy.shouldFallBack(after: error, hasEmittedOutput: false, customEndpointConfigured: true))
        #expect(!PCCFallbackPolicy.shouldFallBack(after: error, hasEmittedOutput: true, customEndpointConfigured: true))
        #expect(!PCCFallbackPolicy.shouldFallBack(after: error, hasEmittedOutput: false, customEndpointConfigured: false))
    }

    @Test("非 PCC 错误（如内容拦截）不回退")
    func otherErrorsDoNotFallBack() {
        #expect(!PCCFallbackPolicy.shouldFallBack(after: AIServiceError.invalidResponse, hasEmittedOutput: false, customEndpointConfigured: true))
    }

    @Test("额度错误文案包含重置时间")
    func quotaMessageIncludesResetDate() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let message = PCCServiceError(failure: .quotaLimitReached(resetDate: date)).errorDescription ?? ""
        #expect(message.contains(PCCServiceError.formatResetDate(date)))
    }
}

// MARK: - 路由

@Suite("RoutingAIService")
struct RoutingAIServiceTests {
    @Test("未选用 PCC 时直接走自有端点")
    func usesCustomWhenNotSelected() async {
        let custom = StubAIService(deltas: [.content("custom"), .done])
        let pcc = StubAIService(deltas: [.content("pcc"), .done])
        let service = RoutingAIService(custom: custom, pcc: pcc, isPCCSelected: { false }, isCustomEndpointConfigured: { true })
        let result = await collectContent(send(service))
        #expect(result.content == "custom")
        #expect(pcc.streamCalls == 0)
    }

    @Test("PCC 首个事件即失败时回退到自有端点")
    func fallsBackBeforeOutput() async {
        let custom = StubAIService(deltas: [.content("custom"), .done])
        let pcc = StubAIService(deltas: [.error(PCCServiceError(failure: .networkFailure))])
        let service = RoutingAIService(custom: custom, pcc: pcc, isPCCSelected: { true }, isCustomEndpointConfigured: { true })
        let result = await collectContent(send(service))
        #expect(result.content == "custom")
        #expect(result.errors.isEmpty)
    }

    @Test("未配置自有端点时把 PCC 错误交给上层")
    func surfacesErrorWithoutCustom() async {
        let custom = StubAIService(deltas: [.content("custom")])
        let pcc = StubAIService(deltas: [.error(PCCServiceError(failure: .serviceUnavailable))])
        let service = RoutingAIService(custom: custom, pcc: pcc, isPCCSelected: { true }, isCustomEndpointConfigured: { false })
        let result = await collectContent(send(service))
        #expect(result.content.isEmpty)
        #expect((result.errors.first as? PCCServiceError)?.failure == .serviceUnavailable)
        #expect(custom.streamCalls == 0)
    }

    @Test("已输出内容后失败不再回退，避免重复回答")
    func noFallbackAfterOutput() async {
        let custom = StubAIService(deltas: [.content("custom")])
        let pcc = StubAIService(deltas: [.content("partial"), .error(PCCServiceError(failure: .networkFailure))])
        let service = RoutingAIService(custom: custom, pcc: pcc, isPCCSelected: { true }, isCustomEndpointConfigured: { true })
        let result = await collectContent(send(service))
        #expect(result.content == "partial")
        #expect(result.errors.count == 1)
        #expect(custom.streamCalls == 0)
    }

    @Test("非流式请求同样回退")
    func simpleMessageFallsBack() async throws {
        let custom = StubAIService(deltas: [], simpleResult: .success("custom"))
        let pcc = StubAIService(deltas: [], simpleResult: .failure(PCCServiceError(failure: .systemNotReady)))
        let service = RoutingAIService(custom: custom, pcc: pcc, isPCCSelected: { true }, isCustomEndpointConfigured: { true })
        #expect(try await service.sendSimpleMessage("x") == "custom")
        #expect(pcc.simpleCalls == 1)
    }
}
