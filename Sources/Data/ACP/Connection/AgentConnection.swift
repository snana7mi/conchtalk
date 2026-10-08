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
    /// 是否成功恢复了请求的既有会话（false 表示新建了会话）。
    let resumed: Bool

    init(
        displayName: String,
        models: ModelsInfo?,
        modes: ModesInfo?,
        configOptions: [SessionConfigOption],
        availableCommands: [AvailableCommand] = [],
        resumed: Bool = false
    ) {
        self.displayName = displayName
        self.models = models
        self.modes = modes
        self.configOptions = configOptions
        self.availableCommands = availableCommands
        self.resumed = resumed
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
    /// 连接代理并尝试恢复既有会话；恢复失败时退回新建会话（通过 `AgentConnectionInfo.resumed` 告知结果）。
    func connect(cwd: String, resumeSessionId: String?) async throws -> AgentConnectionInfo
    /// 代理侧会话标识（ACP sessionId / Claude Code session_id / Codex thread id），用于下次恢复。
    var agentSessionId: String? { get async }
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

extension AgentConnection {
    /// 默认不支持恢复：直接新建会话。
    func connect(cwd: String, resumeSessionId: String?) async throws -> AgentConnectionInfo {
        try await connect(cwd: cwd)
    }

    var agentSessionId: String? { get async { nil } }
}

/// AgentSessionIdValidator：校验从本地存储取出的代理会话 ID，防止拼进远端命令行时注入。
nonisolated enum AgentSessionIdValidator {
    /// 仅允许字母、数字与 `-_.:`，长度 1...200。
    static func isSafe(_ id: String) -> Bool {
        guard !id.isEmpty, id.count <= 200 else { return false }
        return id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.:".contains($0)) }
    }
}
