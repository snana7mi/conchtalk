/// 文件说明：DirectAgentSessionType，直连 ACP 会话的可替换抽象，供协调器注入测试替身。

import Foundation
@preconcurrency import ACPModel

protocol DirectAgentSessionType: Actor {
    var agentInfo: AgentInfo { get }
    var configOptions: [SessionConfigOption] { get async }
    var availableCommands: [AvailableCommand] { get async }
    var modelsInfo: ModelsInfo? { get async }
    var modesInfo: ModesInfo? { get async }

    func setUpdateHandler(_ handler: @escaping @Sendable (SessionUpdate) -> Void) async
    func setDisconnectHandler(_ handler: @escaping @Sendable () -> Void) async
    func setConfigUpdateHandler(_ handler: @escaping @Sendable () -> Void) async
    func setPermissionHandler(_ handler: @escaping @Sendable (ACPPermissionRequest) async -> Bool) async

    @discardableResult
    func connect(cwd: String?) async throws -> String
    /// 连接并尝试恢复既有代理会话（失败自动新建）。
    @discardableResult
    func connect(cwd: String?, resumeSessionId: String?) async throws -> String
    /// 代理侧会话标识（用于下次恢复）。
    var agentSessionId: String? { get async }
    /// 最近一次 connect 是否恢复了既有会话。
    var didResumeSession: Bool { get async }
    func sendPrompt(_ text: String) async throws
    func cancelCurrentPrompt() async
    func setConfigOption(configId: SessionConfigId, value: SessionConfigValueId) async throws
    func setConfigOption(configId: SessionConfigId, value: Bool) async throws
    func setModel(modelId: String) async throws
    func setMode(modeId: String) async throws
    func disconnect() async
}

extension DirectAgentSessionType {
    /// 默认不支持恢复（测试替身等）。
    @discardableResult
    func connect(cwd: String?, resumeSessionId: String?) async throws -> String {
        try await connect(cwd: cwd)
    }

    var agentSessionId: String? { get async { nil } }

    var didResumeSession: Bool { get async { false } }
}
