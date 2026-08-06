/// 文件说明：AgentConnection，直连代理的统一抽象协议。

import Foundation
@preconcurrency import ACPModel

/// AgentConnectionInfo：连接成功后返回的代理信息。
nonisolated struct AgentConnectionInfo: Sendable {
    let displayName: String
    let models: ModelsInfo?
    let modes: ModesInfo?
    let configOptions: [SessionConfigOption]
    let availableCommands: [AvailableCommand]

    init(
        displayName: String,
        models: ModelsInfo?,
        modes: ModesInfo?,
        configOptions: [SessionConfigOption],
        availableCommands: [AvailableCommand] = []
    ) {
        self.displayName = displayName
        self.models = models
        self.modes = modes
        self.configOptions = configOptions
        self.availableCommands = availableCommands
    }
}

/// AgentConnection：直连代理的统一接口。
/// ACP 原生代理、Claude Code、Codex 各有独立实现。
protocol AgentConnection: Actor, Sendable {
    /// 当前 config options 元数据。
    var configOptions: [SessionConfigOption] { get async }
    /// 当前可用 commands 元数据。
    var availableCommands: [AvailableCommand] { get async }
    /// 当前模型元数据。
    var modelsInfo: ModelsInfo? { get async }
    /// 当前模式元数据。
    var modesInfo: ModesInfo? { get async }

    /// 连接代理并完成初始化。
    func connect(cwd: String) async throws -> AgentConnectionInfo
    /// 发送 prompt。流式更新通过 updateHandler 回调。
    func sendPrompt(_ text: String) async throws
    /// 取消当前 prompt。
    func cancelPrompt() async
    /// 断开连接。
    func disconnect() async
    /// 设置流式更新回调。
    func setUpdateHandler(_ handler: @escaping @Sendable (SessionUpdate) -> Void)
    /// 设置断开回调。
    func setDisconnectHandler(_ handler: @escaping @Sendable () -> Void)
    /// 设置 config 更新回调。
    func setConfigUpdateHandler(_ handler: @escaping @Sendable () -> Void)
    /// 设置权限请求回调（代理请求用户审批工具调用时触发）。
    func setPermissionHandler(_ handler: @escaping @Sendable (ACPPermissionRequest) async -> Bool)
}
