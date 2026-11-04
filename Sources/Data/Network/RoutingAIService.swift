/// 文件说明：RoutingAIService，按用户选择在 Apple PCC 与自有端点之间路由 AI 请求，并在 PCC 失败时回退。
import Foundation

/// ToolScopableAIService：可生成「受限工具表 + 可信角色说明」视图的 AI 服务（供 subagent 使用）。
nonisolated protocol ToolScopableAIService: AIServiceProtocol {
    func withToolRegistry(_ toolRegistry: ToolRegistryProtocol, trustedInstructions: String?) -> Self
}

extension UserAIService: ToolScopableAIService {}

/// RoutingAIService：
/// - 每次请求时读取服务来源设置，因此在设置页保存后立即生效。
/// - 选用 PCC 且系统为 iOS 27+ 时走 `PCCAIService`；否则走 `UserAIService`。
/// - PCC 在尚未输出任何内容前失败（不可用、额度用尽、网络 / 服务失败），且用户配置了自有端点时，
///   整轮改用自有端点重试；否则把本地化的 PCC 错误交给界面。
nonisolated final class RoutingAIService: AIServiceProtocol, ToolScopableAIService, @unchecked Sendable {
    private let custom: any ToolScopableAIService
    private let pcc: (any ToolScopableAIService)?
    private let isPCCSelected: @Sendable () -> Bool
    private let isCustomEndpointConfigured: @Sendable () -> Bool

    init(
        custom: any ToolScopableAIService,
        pcc: (any ToolScopableAIService)?,
        isPCCSelected: @escaping @Sendable () -> Bool,
        isCustomEndpointConfigured: @escaping @Sendable () -> Bool
    ) {
        self.custom = custom
        self.pcc = pcc
        self.isPCCSelected = isPCCSelected
        self.isCustomEndpointConfigured = isCustomEndpointConfigured
    }

    /// 生产装配：自有端点始终可用；PCC 仅在 iOS 27+ 创建。
    convenience init(
        keychainService: KeychainServiceProtocol,
        toolRegistry: ToolRegistryProtocol,
        skillRegistry: any SkillLookingUp
    ) {
        let pcc: (any ToolScopableAIService)?
        if #available(iOS 27.0, macOS 27.0, *) {
            pcc = PCCAIService(toolRegistry: toolRegistry, skillRegistry: skillRegistry)
        } else {
            pcc = nil
        }
        self.init(
            custom: UserAIService(keychainService: keychainService, toolRegistry: toolRegistry, skillRegistry: skillRegistry),
            pcc: pcc,
            isPCCSelected: { AIProviderSettings.isPCCSelected() },
            isCustomEndpointConfigured: { AISettings.load(keychainService: keychainService).hasCustomEndpointConfigured }
        )
    }

    func withToolRegistry(_ toolRegistry: ToolRegistryProtocol, trustedInstructions: String?) -> RoutingAIService {
        RoutingAIService(
            custom: custom.withToolRegistry(toolRegistry, trustedInstructions: trustedInstructions),
            pcc: pcc?.withToolRegistry(toolRegistry, trustedInstructions: trustedInstructions),
            isPCCSelected: isPCCSelected,
            isCustomEndpointConfigured: isCustomEndpointConfigured
        )
    }

    /// 本次请求应使用的 PCC 服务；未选用或系统不支持时为 nil。
    private var activePCC: (any ToolScopableAIService)? {
        isPCCSelected() ? pcc : nil
    }

    // MARK: - Streaming

    func sendMessageStreaming(_ message: String, conversationHistory: [Message], serverContext: String, serverID: UUID?, permissionLevel: PermissionLevel, serverName: String, serverCapabilities: ServerCapabilities) -> AsyncStream<StreamingDelta> {
        let custom = self.custom
        let makeCustom: @Sendable () -> AsyncStream<StreamingDelta> = {
            custom.sendMessageStreaming(message, conversationHistory: conversationHistory, serverContext: serverContext, serverID: serverID, permissionLevel: permissionLevel, serverName: serverName, serverCapabilities: serverCapabilities)
        }
        guard let pcc = activePCC else { return makeCustom() }
        return route(
            primary: pcc.sendMessageStreaming(message, conversationHistory: conversationHistory, serverContext: serverContext, serverID: serverID, permissionLevel: permissionLevel, serverName: serverName, serverCapabilities: serverCapabilities),
            fallback: makeCustom
        )
    }

    func sendToolResultStreaming(_ result: String, forToolCall: ToolCall, conversationHistory: [Message], serverContext: String, serverID: UUID?, permissionLevel: PermissionLevel, serverName: String, serverCapabilities: ServerCapabilities) -> AsyncStream<StreamingDelta> {
        let custom = self.custom
        let makeCustom: @Sendable () -> AsyncStream<StreamingDelta> = {
            custom.sendToolResultStreaming(result, forToolCall: forToolCall, conversationHistory: conversationHistory, serverContext: serverContext, serverID: serverID, permissionLevel: permissionLevel, serverName: serverName, serverCapabilities: serverCapabilities)
        }
        guard let pcc = activePCC else { return makeCustom() }
        return route(
            primary: pcc.sendToolResultStreaming(result, forToolCall: forToolCall, conversationHistory: conversationHistory, serverContext: serverContext, serverID: serverID, permissionLevel: permissionLevel, serverName: serverName, serverCapabilities: serverCapabilities),
            fallback: makeCustom
        )
    }

    /// 转发 PCC 流；首个有效输出前遇到可回退错误时，改为转发自有端点流。
    private func route(
        primary: AsyncStream<StreamingDelta>,
        fallback: @escaping @Sendable () -> AsyncStream<StreamingDelta>
    ) -> AsyncStream<StreamingDelta> {
        let isCustomEndpointConfigured = self.isCustomEndpointConfigured
        return AsyncStream { continuation in
            let task = Task {
                var hasEmittedOutput = false
                for await delta in primary {
                    if case .error(let error) = delta,
                       PCCFallbackPolicy.shouldFallBack(
                           after: error,
                           hasEmittedOutput: hasEmittedOutput,
                           customEndpointConfigured: isCustomEndpointConfigured()
                       ) {
                        print("[AIRouting] PCC failed (\(error)); falling back to custom endpoint")
                        for await fallbackDelta in fallback() {
                            continuation.yield(fallbackDelta)
                        }
                        continuation.finish()
                        return
                    }
                    switch delta {
                    case .content, .reasoning, .toolCall: hasEmittedOutput = true
                    default: break
                    }
                    continuation.yield(delta)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Non-streaming

    func generateMemorySummary(recentMessages: [Message], existingConversationMemory: String?, existingServerMemory: String?, existingGlobalMemory: String?) async throws -> MemorySummaryResult {
        try await withFallback { service in
            try await service.generateMemorySummary(
                recentMessages: recentMessages,
                existingConversationMemory: existingConversationMemory,
                existingServerMemory: existingServerMemory,
                existingGlobalMemory: existingGlobalMemory
            )
        }
    }

    func sendSimpleMessage(_ prompt: String) async throws -> String {
        try await withFallback { service in try await service.sendSimpleMessage(prompt) }
    }

    func estimateRequestOverheadTokens(serverContext: String, permissionLevel: PermissionLevel, serverName: String, serverCapabilities: ServerCapabilities) -> Int {
        (activePCC ?? custom).estimateRequestOverheadTokens(
            serverContext: serverContext,
            permissionLevel: permissionLevel,
            serverName: serverName,
            serverCapabilities: serverCapabilities
        )
    }

    private func withFallback<T>(_ operation: (any AIServiceProtocol) async throws -> T) async throws -> T {
        guard let pcc = activePCC else { return try await operation(custom) }
        do {
            return try await operation(pcc)
        } catch {
            guard PCCFallbackPolicy.shouldFallBack(
                after: error,
                hasEmittedOutput: false,
                customEndpointConfigured: isCustomEndpointConfigured()
            ) else { throw error }
            print("[AIRouting] PCC failed (\(error)); falling back to custom endpoint")
            return try await operation(custom)
        }
    }
}
