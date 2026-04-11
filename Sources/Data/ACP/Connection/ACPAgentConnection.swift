/// 文件说明：ACPAgentConnection，将现有 ACPClientConnection 包装为 AgentConnection。

import Foundation
@preconcurrency import ACPModel
@preconcurrency import Citadel

/// ACPAgentConnection：ACP 原生代理的 AgentConnection 实现。
/// 包装现有的 SSHACPTransport + ACPClientConnection，保持原有行为不变。
actor ACPAgentConnection: AgentConnection {
    private let sshClient: SSHClient?
    private let agentInfo: AgentInfo
    private let relayConnection: RelayConnection?

    private var connection: ACPClientConnection?
    private var sessionId: SessionId?

    private var updateHandler: (@Sendable (SessionUpdate) -> Void)?
    private var disconnectHandler: (@Sendable () -> Void)?
    private var configUpdateHandler: (@Sendable () -> Void)?

    /// Agent 广播的 config/model/mode 状态。
    private(set) var configOptions: [SessionConfigOption] = []
    private(set) var availableCommands: [AvailableCommand] = []
    private(set) var modelsInfo: ModelsInfo?
    private(set) var modesInfo: ModesInfo?

    init(sshClient: SSHClient?, agentInfo: AgentInfo, relayConnection: RelayConnection? = nil) {
        self.sshClient = sshClient
        self.agentInfo = agentInfo
        self.relayConnection = relayConnection
    }

    func setUpdateHandler(_ handler: @escaping @Sendable (SessionUpdate) -> Void) {
        updateHandler = handler
    }

    func setDisconnectHandler(_ handler: @escaping @Sendable () -> Void) {
        disconnectHandler = handler
    }

    func setConfigUpdateHandler(_ handler: @escaping @Sendable () -> Void) {
        configUpdateHandler = handler
    }

    func connect(cwd: String) async throws -> AgentConnectionInfo {
        configOptions = []
        availableCommands = []
        modelsInfo = nil
        modesInfo = nil

        let commandCandidates = DirectAgentSession.acpCommandCandidates(for: agentInfo)
        var nextCommandIndex = 0

        let outcome = try await DirectAgentSession.executeConnectWithRetry(
            agentType: agentInfo.type
        ) { [weak self, sshClient] in
            let command = commandCandidates[min(nextCommandIndex, commandCandidates.count - 1)]
            nextCommandIndex += 1

            let transport: any ACPTransport
            if let relay = self?.relayConnection {
                transport = await RelayACPTransport(
                    relayConnection: relay,
                    agentCommand: command,
                    cwd: cwd
                )
            } else {
                guard let sshClient else {
                    throw ACPConnectionError.notConnected
                }
                transport = await SSHACPTransport(sshClient: sshClient, agentCommand: command)
            }
            let requestTimeoutSeconds: TimeInterval = self?.agentInfo.type == .gemini ? 240 : 120
            let candidateConnection = ACPClientConnection(
                transport: transport,
                requestTimeoutSeconds: requestTimeoutSeconds
            )

            // 必须在 connect() 前注册 handler，避免丢失握手期间的通知
            await candidateConnection.setUpdateHandler { [weak self] update in
                Task { await self?.forwardUpdate(update) }
            }

            do {
                let initResult = try await candidateConnection.connect()
                let session = try await candidateConnection.createSession(cwd: cwd)
                return (connection: candidateConnection, initResult: initResult, session: session)
            } catch {
                await candidateConnection.disconnect()
                throw error
            }
        }

        let conn = outcome.connection
        self.connection = conn
        self.sessionId = outcome.session.sessionId
        self.modelsInfo = outcome.session.models
        self.modesInfo = outcome.session.modes
        self.configOptions = outcome.session.configOptions ?? []

        let displayName = outcome.initResult.agentInfo?.name ?? agentInfo.type.rawValue
        return AgentConnectionInfo(
            displayName: displayName,
            models: modelsInfo,
            modes: modesInfo,
            configOptions: configOptions,
            availableCommands: availableCommands
        )
    }

    func sendPrompt(_ text: String) async throws {
        guard let conn = connection, let sid = sessionId else {
            throw ACPConnectionError.notConnected
        }
        do {
            _ = try await conn.prompt(sessionId: sid, text: text)
        } catch {
            if case ACPConnectionError.disconnected = error {
                disconnectHandler?()
            }
            throw error
        }
    }

    func cancelPrompt() async {
        guard let conn = connection, let sid = sessionId else { return }
        try? await conn.cancelPrompt(sessionId: sid)
    }

    func disconnect() async {
        if let conn = connection {
            await conn.disconnect()
        }
        connection = nil
        sessionId = nil
        configOptions = []
        availableCommands = []
        modelsInfo = nil
        modesInfo = nil
    }

    // MARK: - ACP 专有配置操作

    /// 设置 config option（select 类型）。
    func setConfigOption(configId: SessionConfigId, value: SessionConfigValueId) async throws {
        guard let conn = connection, let sid = sessionId else {
            throw ACPConnectionError.notConnected
        }
        try await conn.setConfigOption(sessionId: sid, configId: configId, value: .select(value))
    }

    /// 设置 config option（boolean 类型）。
    func setConfigOption(configId: SessionConfigId, value: Bool) async throws {
        guard let conn = connection, let sid = sessionId else {
            throw ACPConnectionError.notConnected
        }
        try await conn.setConfigOption(sessionId: sid, configId: configId, value: .boolean(value))
    }

    /// 切换 model。
    func setModel(modelId: String) async throws {
        guard let conn = connection, let sid = sessionId else {
            throw ACPConnectionError.notConnected
        }
        try await conn.setModel(sessionId: sid, modelId: modelId)
    }

    /// 切换 mode。
    func setMode(modeId: String) async throws {
        guard let conn = connection, let sid = sessionId else {
            throw ACPConnectionError.notConnected
        }
        try await conn.setMode(sessionId: sid, modeId: modeId)
    }

    /// 转发 ACP 更新，拦截 config 状态。
    private func forwardUpdate(_ update: SessionUpdate) {
        switch update {
        case .configOptionUpdate(let options):
            configOptions = options
            configUpdateHandler?()
        case .availableCommandsUpdate(let commands):
            availableCommands = commands
            configUpdateHandler?()
        case .currentModeUpdate(let modeId):
            if let modes = modesInfo {
                modesInfo = ModesInfo(currentModeId: modeId, availableModes: modes.availableModes)
                configUpdateHandler?()
            }
        default:
            break
        }
        updateHandler?(update)
    }
}
