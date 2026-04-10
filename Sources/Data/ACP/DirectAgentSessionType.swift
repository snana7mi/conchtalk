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

    @discardableResult
    func connect(cwd: String?) async throws -> String
    func sendPrompt(_ text: String) async throws
    func cancelCurrentPrompt() async
    func setConfigOption(configId: SessionConfigId, value: SessionConfigValueId) async throws
    func setConfigOption(configId: SessionConfigId, value: Bool) async throws
    func setModel(modelId: String) async throws
    func setMode(modeId: String) async throws
    func disconnect() async
}
