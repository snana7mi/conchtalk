/// 文件说明：DirectAgentSession，封装直连模式下代理会话的完整生命周期。

import Foundation
@preconcurrency import ACPModel
import NIOCore
import NIOFoundationCompat
@preconcurrency import Citadel

/// DirectAgentSession：
/// 管理用户与远端编码代理的直连对话。根据 AgentType 路由到不同的 Connection 实现：
/// - Claude → ClaudeCodeConnection（原生 stream-json 协议）
/// - Codex → CodexConnection（原生 JSON-RPC 协议）
/// - 其他 → ACPAgentConnection（ACP 协议）
actor DirectAgentSession: DirectAgentSessionType {
    let agentInfo: AgentInfo  // Domain 层的 AgentInfo
    nonisolated(unsafe) private let sshClient: SSHClient?

    private var agentConnection: (any AgentConnection)?
    private var updateHandler: (@Sendable (SessionUpdate) -> Void)?
    /// 会话断开回调，用于通知 ChatViewModel 自动退出直连模式。
    private var disconnectHandler: (@Sendable () -> Void)?
    /// 当前正在执行的 prompt Task，用于取消。
    private var activePromptTask: Task<Void, Error>?

    private(set) var isConnected = false
    /// Agent 广播的 config options（通用配置，来自 session/new 或 configOptionUpdate）。
    private(set) var configOptions: [SessionConfigOption] = []
    /// Agent 广播的可用 slash commands。
    private(set) var availableCommands: [AvailableCommand] = []
    /// Agent 提供的可用 models（来自 session/new response）。
    private(set) var modelsInfo: ModelsInfo?
    /// Agent 提供的可用 modes（来自 session/new response）。
    private(set) var modesInfo: ModesInfo?
    /// config/command 状态变化回调，用于通知 ViewModel 刷新。
    private var configUpdateHandler: (@Sendable () -> Void)?

    // MARK: - 连接类型路由

    /// ConnectionType：内部连接类型标识。
    nonisolated enum ConnectionType: Equatable {
        case acp
        case claudeCode
        case codex
    }

    /// 根据 AgentType 决定使用哪种 Connection。
    nonisolated static func connectionType(for agentType: AgentType) -> ConnectionType {
        switch agentType {
        case .claude: return .claudeCode
        case .codex: return .codex
        default: return .acp
        }
    }

    init(agentInfo: AgentInfo, sshClient: SSHClient?) {
        self.agentInfo = agentInfo
        self.sshClient = sshClient
    }

    /// 设置流式更新回调。
    func setUpdateHandler(_ handler: @escaping @Sendable (SessionUpdate) -> Void) {
        self.updateHandler = handler
    }

    /// 设置断开回调，当连接异常断开时通知外部。
    func setDisconnectHandler(_ handler: @escaping @Sendable () -> Void) {
        self.disconnectHandler = handler
    }

    /// 设置 config/command 状态更新回调。
    func setConfigUpdateHandler(_ handler: @escaping @Sendable () -> Void) {
        self.configUpdateHandler = handler
    }

    private func notifyConfigChanged() {
        configUpdateHandler?()
    }

    private func applyInitialConnectionInfo(_ info: AgentConnectionInfo) {
        self.modelsInfo = info.models
        self.modesInfo = info.modes
        self.configOptions = info.configOptions
        self.availableCommands = info.availableCommands
    }

    private func resetConnectionState() {
        agentConnection = nil
        configOptions = []
        availableCommands = []
        modelsInfo = nil
        modesInfo = nil
    }

    // MARK: - 生命周期

    /// 连接到代理并创建会话。返回代理显示名。
    @discardableResult
    func connect(cwd: String? = nil) async throws -> String {
        // 解析工作目录：cwd 未指定时通过 SSH 探测远端 home 目录
        // （ACP 协议的 cwd 是文件系统路径，`~` 和 `$HOME` 不会被展开）
        let resolvedCwd: String
        if let cwd {
            resolvedCwd = cwd
        } else if let sshClient {
            resolvedCwd = await Self.resolveHomeDirectory(sshClient: sshClient)
        } else {
            resolvedCwd = "~"
        }

        // 根据代理类型创建对应的 Connection
        let connType = Self.connectionType(for: agentInfo.type)
        print("[DirectAgentSession] Creating connection: type=\(connType), agent=\(agentInfo.type.rawValue), cwd=\(resolvedCwd)")

        let connection: any AgentConnection
        switch connType {
        case .claudeCode:
            connection = ClaudeCodeConnection(sshClient: sshClient!)
        case .codex:
            connection = CodexConnection(sshClient: sshClient!)
        case .acp:
            connection = ACPAgentConnection(sshClient: sshClient, agentInfo: agentInfo)
        }

        // 设置回调（必须在 connect() 前注册，避免丢失握手期间的通知）
        await connection.setUpdateHandler { [weak self] update in
            Task { await self?.forwardUpdate(update) }
        }
        await connection.setDisconnectHandler { [weak self] in
            Task { await self?.handleDisconnect() }
        }
        await connection.setConfigUpdateHandler { [weak self] in
            Task { await self?.handleConfigUpdate() }
        }

        // 连接
        let info = try await connection.connect(cwd: resolvedCwd)

        self.agentConnection = connection
        self.isConnected = true
        applyInitialConnectionInfo(info)

        print("[DirectAgentSession] Connected to agent: \(info.displayName)")

        #if DEBUG
        print("[DirectAgentSession] Models: \(info.models?.availableModels.count ?? 0), Modes: \(info.modes?.availableModes.count ?? 0), ConfigOptions: \(info.configOptions.count)")
        #endif

        // 通知 ViewModel 初始配置已就绪
        notifyConfigChanged()

        return info.displayName
    }

    /// 发送 prompt 并等待代理完成回复。支持通过 cancelCurrentPrompt() 取消。
    func sendPrompt(_ text: String) async throws {
        guard let conn = agentConnection else {
            throw ACPConnectionError.notConnected
        }

        let task = Task {
            try await conn.sendPrompt(text)
        }
        activePromptTask = task

        do {
            try await task.value
            activePromptTask = nil
        } catch {
            activePromptTask = nil
            if case ACPConnectionError.disconnected = error {
                await handleDisconnect()
            }
            throw error
        }
    }

    /// 取消当前正在执行的 prompt。
    func cancelCurrentPrompt() async {
        activePromptTask?.cancel()
        activePromptTask = nil

        await agentConnection?.cancelPrompt()
    }

    // MARK: - Config（仅 ACP 代理支持）

    /// 设置 config option（select 类型）。仅 ACP 代理支持。
    func setConfigOption(configId: SessionConfigId, value: SessionConfigValueId) async throws {
        guard let acpConn = agentConnection as? ACPAgentConnection else { return }
        try await acpConn.setConfigOption(configId: configId, value: value)
    }

    /// 设置 config option（boolean 类型）。仅 ACP 代理支持。
    func setConfigOption(configId: SessionConfigId, value: Bool) async throws {
        guard let acpConn = agentConnection as? ACPAgentConnection else { return }
        try await acpConn.setConfigOption(configId: configId, value: value)
    }

    /// 切换 model。ACP 代理走 RPC，Codex 通过 turn/start 参数传递。
    func setModel(modelId: String) async throws {
        if let acpConn = agentConnection as? ACPAgentConnection {
            try await acpConn.setModel(modelId: modelId)
        } else if let codexConn = agentConnection as? CodexConnection {
            await codexConn.setModel(modelId: modelId)
        }
        // Claude Code 不支持运行时切换 model，静默忽略

        // 乐观更新本地状态
        if var models = modelsInfo {
            models = ModelsInfo(currentModelId: modelId, availableModels: models.availableModels)
            modelsInfo = models
            configUpdateHandler?()
        }
    }

    /// 切换 mode。ACP 代理走 RPC，Codex 通过 turn/start 参数传递。
    func setMode(modeId: String) async throws {
        if let acpConn = agentConnection as? ACPAgentConnection {
            try await acpConn.setMode(modeId: modeId)
        } else if let codexConn = agentConnection as? CodexConnection {
            await codexConn.setMode(modeId: modeId)
        }
        // Claude Code 不支持运行时切换 mode，静默忽略

        // 乐观更新本地状态
        if var modes = modesInfo {
            modes = ModesInfo(currentModeId: modeId, availableModes: modes.availableModes)
            modesInfo = modes
            configUpdateHandler?()
        }
    }

    /// 断开连接，清理所有资源。
    func disconnect() async {
        activePromptTask?.cancel()
        activePromptTask = nil

        isConnected = false
        if let conn = agentConnection {
            await conn.disconnect()
        }
        resetConnectionState()

        await cleanupRemoteACPProcess()
    }

    /// 通过 SSH 执行 kill 命令清理残留的代理进程。
    /// 使用代理的命令作为匹配模式，避免误杀非相关进程。
    private func cleanupRemoteACPProcess() async {
        // wrapperCommand 非空时使用包装命令，其他代理使用 path + acpFlag
        let processPattern = agentInfo.wrapperCommand ?? "\(agentInfo.path) \(agentInfo.type.acpFlag)"
        // pkill -f 按完整命令行匹配；`|| true` 防止无匹配时返回非零退出码
        let command = "pkill -f '\(processPattern)' 2>/dev/null || true"
        do {
            _ = try await sshClient?.executeCommand(command)
        } catch {
            // 清理失败不阻断断连流程（SSH 连接可能已断开）
            print("[DirectAgentSession] Failed to cleanup remote process: \(error)")
        }
    }

    // MARK: - 内部

    /// 转发更新到外部 handler，同时拦截 config/command 更新并存储。
    private func forwardUpdate(_ update: SessionUpdate) {
        // 拦截 config/command 状态更新
        switch update {
        case .configOptionUpdate(let options):
            configOptions = options
            notifyConfigChanged()
        case .availableCommandsUpdate(let commands):
            availableCommands = commands
            notifyConfigChanged()
        case .currentModeUpdate(let modeId):
            // Agent 通知 mode 已变更
            if let modes = modesInfo {
                modesInfo = ModesInfo(currentModeId: modeId, availableModes: modes.availableModes)
                notifyConfigChanged()
            }
        default:
            break
        }
        // 所有 update 仍转发给原有 handler（流式 UI 不受影响）
        updateHandler?(update)
    }

    /// 处理连接断开。
    private func handleDisconnect() async {
        isConnected = false
        disconnectHandler?()
    }

    /// 处理 config 更新（从 Connection 的 configUpdateHandler 桥接）。
    private func handleConfigUpdate() async {
        guard let connection = agentConnection else { return }
        configOptions = await connection.configOptions
        availableCommands = await connection.availableCommands
        modelsInfo = await connection.modelsInfo
        modesInfo = await connection.modesInfo
        notifyConfigChanged()
    }

    /// 通过 SSH 执行 `echo $HOME` 探测远端用户 home 目录。
    /// 失败时 fallback 到 `/`。
    private static func resolveHomeDirectory(sshClient: SSHClient) async -> String {
        do {
            let stream = try await sshClient.executeCommandStream("echo $HOME")
            var stdout = ByteBuffer()
            for try await chunk in stream {
                if case .stdout(var buf) = chunk {
                    stdout.writeBuffer(&buf)
                }
            }
            let home = String(data: Data(buffer: stdout), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return home.isEmpty ? "/" : home
        } catch {
            print("[DirectAgentSession] Failed to resolve home directory: \(error)")
            return "/"
        }
    }

    /// 构造 ACP 启动命令候选集。
    /// openclaw 优先使用 reset-session，在失败重试时回退到非 reset，降低网关瞬态失败影响。
    nonisolated static func acpCommandCandidates(for agentInfo: AgentInfo) -> [String] {
        guard agentInfo.type == .openclaw else {
            return [agentInfo.acpCommand]
        }

        let primary = agentInfo.acpCommand
        let fallback = "\(agentInfo.path) \(agentInfo.type.acpFlag) --session agent:main:main"
        return primary == fallback ? [primary] : [primary, fallback]
    }

    /// openclaw 连接错误分型：用于差异化退避，减少无效等待。
    private enum OpenClawRetryErrorKind {
        case challengeTimeout
        case gatewayClosed
        case other
    }

    /// 提取错误文本并做粗粒度分类（基于实测常见失败文案）。
    nonisolated private static func classifyOpenClawRetryError(_ error: Error) -> OpenClawRetryErrorKind {
        let text = "\(error.localizedDescription) \(String(describing: error))".lowercased()
        if text.contains("challenge timeout") {
            return .challengeTimeout
        }
        if text.contains("gateway connect failed")
            || text.contains("gateway closed")
            || text.contains("closed before ready") {
            return .gatewayClosed
        }
        return .other
    }

    /// 计算连接重试延迟。openclaw 按错误类型差异化退避，其它代理保持保守默认值。
    nonisolated static func retryDelayForAttempt(agentType: AgentType, attempt: Int, error: Error) -> Duration {
        guard agentType == .openclaw else {
            return .milliseconds(400 * attempt)
        }

        switch classifyOpenClawRetryError(error) {
        case .gatewayClosed:
            // 网关瞬断通常可快速恢复，使用短退避。
            return .milliseconds(300 * attempt)
        case .challengeTimeout:
            // challenge 超时常与初始化拥塞相关，拉长退避。
            return .seconds(2 * attempt)
        case .other:
            return .milliseconds(800 * attempt)
        }
    }

    /// 针对 ACP 连接执行分级重试。
    /// - Note: 仅 openclaw 启用额外重试，其它代理保持单次尝试，避免掩盖真实配置错误。
    nonisolated static func executeConnectWithRetry<T>(
        agentType: AgentType,
        sleep: @escaping (Duration) async throws -> Void = { duration in
            try await Task.sleep(for: duration)
        },
        onRetry: (_ attempt: Int, _ maxAttempts: Int, _ error: Error) async -> Void = { _, _, _ in },
        operation: () async throws -> T
    ) async throws -> T {
        let maxAttempts = agentType == .openclaw ? 3 : 1
        var lastError: Error?

        for attempt in 1...maxAttempts {
            try Task.checkCancellation()
            do {
                return try await operation()
            } catch {
                lastError = error
                guard attempt < maxAttempts else { throw error }
                await onRetry(attempt, maxAttempts, error)
                let delay = retryDelayForAttempt(agentType: agentType, attempt: attempt, error: error)
                try await sleep(delay)
            }
        }

        throw lastError ?? ACPConnectionError.notConnected
    }
}
