/// 文件说明：DirectSessionCoordinator，编排直连模式 session 的生命周期、连接、流式和旋转。
import Foundation
import SwiftUI
@preconcurrency import ACPModel
@preconcurrency import Citadel

/// DirectSessionEvent：直连 session 协调器发出的事件，供上层消费。
enum DirectSessionEvent: Sendable {
    /// 生命周期状态变化。
    case lifecycleChanged(DirectModeLifecycle)
    /// 元数据更新（命令、模型、模式、配置项）。
    case metadataUpdated(DirectModeMetadata)
    /// 流式更新（thinking、text、toolCall 等）。
    case streamUpdate(AgentStreamEvent)
    /// 消息已就绪，可用于追加和持久化。
    case messageReady(Message)
    /// 退出时的 AI 上下文摘要。
    case contextSummaryReady(String)
    /// 错误信息。
    case error(String)
    /// 代理请求用户审批工具调用。
    case permissionRequested(ACPPermissionRequest)
}

/// DirectSessionCoordinator：
/// 直连模式 session 编排层，负责：
/// 1. 管理 DirectAgentSessionType 实例的生命周期
/// 2. 驱动连接/断连/发送/取消/旋转状态机
/// 3. 通过 AsyncStream 发出类型化事件
/// 4. 不直接追加消息或操作 UI 状态——由调用方负责
@Observable
@MainActor
final class DirectSessionCoordinator {
    typealias SessionFactory = @Sendable (_ agent: AgentInfo, _ sshClient: SSHClient?) -> any DirectAgentSessionType

    // MARK: - 公开状态

    /// 当前 session 状态快照（只读）。
    private(set) var state = DirectSessionState()

    // MARK: - 事件流

    /// 事件流，供外部观察者消费。
    let events: AsyncStream<DirectSessionEvent>
    private let eventContinuation: AsyncStream<DirectSessionEvent>.Continuation

    // MARK: - 内部状态

    private let sessionFactory: SessionFactory
    private var nextSessionTokenRawValue: UInt64 = 0
    private var directSession: (any DirectAgentSessionType)?
    private var directPromptTask: Task<Void, Never>?
    private var connectTask: Task<Void, Never>?
    private var suppressedDisconnectSessionIDs: Set<ObjectIdentifier> = []
    private var activeAgentInfo: AgentInfo?
    private var lastSSHClient: SSHClient?

    // MARK: - Init

    init(
        sessionFactory: @escaping SessionFactory = { agent, sshClient in
            DirectAgentSession(agentInfo: agent, sshClient: sshClient)
        }
    ) {
        let (stream, continuation) = AsyncStream.makeStream(of: DirectSessionEvent.self)
        self.events = stream
        self.eventContinuation = continuation
        self.sessionFactory = sessionFactory
    }

    deinit {
        eventContinuation.finish()
    }

    // MARK: - UI 便利属性

    /// 当前活跃的 agent session（供配置操作直接调用）。
    var session: (any DirectAgentSessionType)? { directSession }

    /// 是否正在连接 agent。
    var isConnectingToAgent: Bool {
        state.lifecycle == .connecting
    }

    /// 正在连接的 agent 类型。
    var connectingAgentType: AgentType? {
        guard state.lifecycle == .connecting else { return nil }
        return state.activeAgent?.type
    }

    /// 是否有活跃的 session（connected 或 executing）。
    var hasActiveSession: Bool {
        switch state.lifecycle {
        case .connected, .executing: return true
        default: return false
        }
    }

    // MARK: - 公开 API

    /// 连接到指定 agent。
    /// - Parameter currentMessageCount: 当前消息列表长度，用于后续上下文摘要提取。
    func connect(agent: AgentInfo, cwd: String? = nil, sshClient: SSHClient? = nil, currentMessageCount: Int = 0) async {
        beginConnecting(to: agent)
        state.cwd = cwd
        state.directModeStartMessageCount = currentMessageCount
        lastSSHClient = sshClient

        let task = Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.connectSession(agent: agent, cwd: cwd, sshClient: sshClient)
            } catch is CancellationError {
                self.resetToIdle()
            } catch {
                if let token = self.state.currentSessionToken {
                    self.markFailed(error.localizedDescription, sessionToken: token)
                }
                self.eventContinuation.yield(.error(error.localizedDescription))
            }
            self.connectTask = nil
        }

        connectTask = task
        await task.value
    }

    /// 发送 prompt（同步启动，异步执行）。
    func sendPrompt(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard canSend, let session = directSession, let activeAgent = state.activeAgent else { return }

        let source = ChatMode.directAgent(agentName: activeAgent.name, agentType: activeAgent.type).toMessageSource

        // 发出用户消息事件
        let userMsg = Message(role: .user, content: trimmed, source: source)
        eventContinuation.yield(.messageReady(userMsg))

        state.accumulatedEvents = []
        markExecuting(true)

        directPromptTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await session.sendPrompt(trimmed)
                guard !Task.isCancelled else { return }
                _ = self.emitAssistantMessageIfNeeded(
                    source: source,
                    fallbackContent: "Done",
                    allowEmptyContent: true
                )
                self.markExecuting(false)
                self.directPromptTask = nil
            } catch {
                guard !Task.isCancelled else { return }

                if error is CancellationError {
                    self.state.accumulatedEvents = []
                    self.markExecuting(false)
                    self.directPromptTask = nil
                    return
                }

                if self.emitAssistantMessageIfNeeded(source: source) {
                    self.markExecuting(false)
                    self.directPromptTask = nil

                    if case ACPConnectionError.disconnected = error {
                        await self.disconnect()
                    }
                    return
                }

                self.state.accumulatedEvents = []
                self.markExecuting(false)
                self.directPromptTask = nil

                let errorMsg = Message(
                    role: .assistant,
                    content: "Error: \(error.localizedDescription)",
                    source: source
                )
                self.eventContinuation.yield(.messageReady(errorMsg))

                if case ACPConnectionError.disconnected = error {
                    await self.disconnect()
                }
            }
        }
    }

    /// 异步版本的 sendPrompt，等待执行完成。
    func sendPromptAndWait(_ text: String) async {
        sendPrompt(text)
        // 等待 prompt task 完成
        if let task = directPromptTask {
            await task.value
        }
    }

    /// 取消当前正在执行的 prompt。
    func cancelPrompt() {
        resolvePermission(approved: false)
        guard canCancel else { return }
        directPromptTask?.cancel()
        directPromptTask = nil
        state.accumulatedEvents = []
        markExecuting(false)

        Task { [directSession] in
            await directSession?.cancelCurrentPrompt()
        }
    }

    /// 断开连接并生成上下文摘要。
    /// - Parameter messages: 当前聊天消息列表，用于提取直连模式期间的对话摘要。
    @discardableResult
    func disconnect(messages: [Message] = []) async -> String? {
        resolvePermission(approved: false)
        guard let agent = state.activeAgent else { return nil }
        let sessionToken = state.currentSessionToken
        let agentName = agent.name

        transitionLifecycle(to: .disconnecting)
        directPromptTask?.cancel()
        directPromptTask = nil

        if let session = directSession {
            await session.cancelCurrentPrompt()
            suppressNextDisconnectCallback(for: session)
            await session.disconnect()
        }

        // 构建上下文摘要
        let summary = buildContextSummary(agentName: agentName, messages: messages)
        if let summary {
            eventContinuation.yield(.contextSummaryReady(summary))
        }

        state.accumulatedEvents = []

        if let sessionToken {
            finishDisconnecting(sessionToken: sessionToken)
        } else {
            resetToIdle()
        }

        return summary
    }

    /// 从直连模式消息中构建 AI 上下文摘要。
    private func buildContextSummary(agentName: String, messages: [Message]) -> String? {
        let directMessages = messages
            .dropFirst(state.directModeStartMessageCount)
            .filter { if case .directAgent = $0.source { return true }; return false }
        guard !directMessages.isEmpty else { return nil }

        let summary = directMessages.prefix(20).map { message in
            let role = message.role == .user ? "User" : agentName
            let content = message.content.prefix(200)
            return "- \(role): \(content)"
        }.joined(separator: "\n")

        return "[Context] Direct session with \(agentName):\n\(summary)"
    }

    /// context break 后旋转 session：断开旧 session，创建新 session，保留 agent 身份。
    @discardableResult
    func rotateAfterContextBreak() async -> Bool {
        resolvePermission(approved: false)
        guard let agent = activeAgentInfo, let currentSession = directSession else { return false }

        directPromptTask?.cancel()
        directPromptTask = nil
        state.accumulatedEvents = []

        await currentSession.cancelCurrentPrompt()
        suppressNextDisconnectCallback(for: currentSession)
        await currentSession.disconnect()
        directSession = nil
        state.metadata = DirectModeMetadata()

        let savedToken = state.currentSessionToken
        if savedToken != nil {
            beginConnecting(to: agent, displayName: state.activeAgent?.name)
            // 保留原 token（避免 beginConnecting 生成新 token 后与外部不一致）
            state.currentSessionToken = savedToken
        }

        do {
            _ = try await connectSession(
                agent: agent,
                cwd: state.cwd,
                sshClient: lastSSHClient
            )
            return true
        } catch {
            resetToIdle()
            eventContinuation.yield(.error(error.localizedDescription))
            return false
        }
    }

    /// 取消正在进行的连接。
    func cancelConnecting() {
        guard state.lifecycle == .connecting else { return }
        connectTask?.cancel()
        connectTask = nil
        resetToIdle()
    }

    // MARK: - 直连审批

    /// 待决审批 continuation（单槽：同一 session 串行发权限请求，单槽足够）。
    private var pendingPermissionContinuation: CheckedContinuation<Bool, Never>?
    /// 审批超时任务句柄。
    private var permissionTimeoutTask: Task<Void, Never>?
    /// 审批超时时长（秒）：超时自动 deny，防止代理侧永久挂起。
    private static let permissionTimeoutSeconds: TimeInterval = 300

    /// 挂起等待用户审批（permission handler 回调入口，MainActor 串行）。
    private func requestPermission(_ request: ACPPermissionRequest) async -> Bool {
        // 防御：清掉可能残留的旧请求（one-shot，无残留时为 no-op）
        resolvePermission(approved: false)
        return await withCheckedContinuation { continuation in
            pendingPermissionContinuation = continuation
            eventContinuation.yield(.permissionRequested(request))
            permissionTimeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(Self.permissionTimeoutSeconds))
                guard !Task.isCancelled else { return }
                self?.resolvePermission(approved: false)
            }
        }
    }

    /// 用户审批结果回填（UI 调用；one-shot，无待决请求时为 no-op）。
    /// 参照 TaskExecutionCoordinator.resolveApprovalContinuation 的唯一 resume 入口模式。
    func resolvePermission(approved: Bool) {
        guard let continuation = pendingPermissionContinuation else { return }
        pendingPermissionContinuation = nil
        permissionTimeoutTask?.cancel()
        permissionTimeoutTask = nil
        continuation.resume(returning: approved)
    }

    // MARK: - 配置操作

    /// 设置直连 agent 的模型并更新本地元数据。
    func setModel(modelId: String) {
        Task {
            do {
                try await directSession?.setModel(modelId: modelId)
                if var models = state.metadata.models {
                    models = ModelsInfo(currentModelId: modelId, availableModels: models.availableModels)
                    state.metadata.models = models
                }
            } catch {
                print("[DirectSessionCoordinator] Failed to set model: \(error)")
            }
        }
    }

    /// 设置直连 agent 的模式并更新本地元数据。
    func setMode(modeId: String) {
        Task {
            do {
                try await directSession?.setMode(modeId: modeId)
                if var modes = state.metadata.modes {
                    modes = ModesInfo(currentModeId: modeId, availableModes: modes.availableModes)
                    state.metadata.modes = modes
                }
            } catch {
                print("[DirectSessionCoordinator] Failed to set mode: \(error)")
            }
        }
    }

    /// 设置直连 agent 的配置项。
    func setConfigOption(configId: SessionConfigId, value: SessionConfigOptionValue) {
        Task {
            do {
                switch value {
                case .select(let selectVal):
                    try await directSession?.setConfigOption(configId: configId, value: selectVal)
                case .boolean(let boolVal):
                    try await directSession?.setConfigOption(configId: configId, value: boolVal)
                }
            } catch {
                print("[DirectSessionCoordinator] Failed to set config option: \(error)")
            }
        }
    }

    // MARK: - 内部：状态机

    private var canSend: Bool {
        state.activeAgent != nil && state.lifecycle == .connected
    }

    private var canCancel: Bool {
        state.activeAgent != nil && state.lifecycle == .executing
    }

    private func beginNewSession() -> DirectSessionToken {
        nextSessionTokenRawValue += 1
        return DirectSessionToken(rawValue: nextSessionTokenRawValue)
    }

    private func beginConnecting(to agent: AgentInfo, displayName: String? = nil) {
        state.metadata = DirectModeMetadata()
        state.currentSessionToken = beginNewSession()
        state.activeAgent = .init(name: displayName ?? agent.type.displayName, type: agent.type)
        transitionLifecycle(to: .connecting)
    }

    private func markConnected(displayName: String? = nil, sessionToken: DirectSessionToken) {
        guard state.activeAgent != nil else { return }
        guard let currentToken = state.currentSessionToken, sessionToken == currentToken else { return }
        guard state.lifecycle == .connecting else { return }
        if let displayName, let currentAgent = state.activeAgent {
            state.activeAgent = .init(name: displayName, type: currentAgent.type)
        }
        transitionLifecycle(to: .connected)
    }

    private func markExecuting(_ isExecuting: Bool) {
        guard state.activeAgent != nil else { return }
        if isExecuting {
            guard state.lifecycle == .connected || state.lifecycle == .executing else { return }
            transitionLifecycle(to: .executing)
        } else {
            guard state.lifecycle == .executing else { return }
            transitionLifecycle(to: .connected)
        }
    }

    private func markFailed(_ message: String?, sessionToken: DirectSessionToken) {
        guard state.activeAgent != nil else { return }
        guard let currentToken = state.currentSessionToken, sessionToken == currentToken else { return }
        guard state.lifecycle != .disconnecting else { return }
        state.metadata = DirectModeMetadata()
        transitionLifecycle(to: .failed(message: message))
    }

    private func finishDisconnecting(sessionToken: DirectSessionToken) {
        guard let currentToken = state.currentSessionToken, sessionToken == currentToken else { return }
        guard state.lifecycle == .disconnecting else { return }
        resetToIdle()
    }

    private func resetToIdle() {
        state.lifecycle = .idle
        state.activeAgent = nil
        state.metadata = DirectModeMetadata()
        state.currentSessionToken = nil
        state.cwd = nil
        state.accumulatedEvents = []
        activeAgentInfo = nil
        directSession = nil
        lastSSHClient = nil
        eventContinuation.yield(.lifecycleChanged(.idle))
    }

    private func transitionLifecycle(to newLifecycle: DirectModeLifecycle) {
        state.lifecycle = newLifecycle
        eventContinuation.yield(.lifecycleChanged(newLifecycle))
    }

    // MARK: - 内部：Session 管理

    private func connectSession(
        agent: AgentInfo,
        cwd: String?,
        sshClient: SSHClient?
    ) async throws -> String {
        let session = sessionFactory(agent, sshClient)
        await installSessionHandlers(on: session)

        do {
            let displayName = try await session.connect(cwd: cwd)
            guard !Task.isCancelled else {
                suppressNextDisconnectCallback(for: session)
                await session.disconnect()
                throw CancellationError()
            }

            directSession = session
            activeAgentInfo = agent

            if let sessionToken = state.currentSessionToken {
                markConnected(displayName: displayName, sessionToken: sessionToken)
                await syncSessionMetadata(from: session, sessionToken: sessionToken)
            }

            return displayName
        } catch {
            suppressNextDisconnectCallback(for: session)
            await session.disconnect()
            throw error
        }
    }

    private func syncSessionMetadata(from session: any DirectAgentSessionType, sessionToken: DirectSessionToken? = nil) async {
        let token = sessionToken ?? state.currentSessionToken
        guard let token else { return }
        let commands = await session.availableCommands
        let models = await session.modelsInfo
        let modes = await session.modesInfo
        let configOptions = await session.configOptions

        guard state.activeAgent != nil else { return }
        guard let currentToken = state.currentSessionToken, token == currentToken else { return }
        guard state.lifecycle == .connecting || state.lifecycle == .connected || state.lifecycle == .executing else { return }

        state.metadata.commands = commands
        state.metadata.models = models
        state.metadata.modes = modes
        state.metadata.configOptions = configOptions

        eventContinuation.yield(.metadataUpdated(state.metadata))
    }

    private func installSessionHandlers(on session: any DirectAgentSessionType) async {
        let sessionID = sessionIdentity(session)

        await session.setUpdateHandler { [weak self] update in
            guard let self else { return }
            Task { @MainActor [weak self] in
                self?.handleSessionUpdate(update, sessionID: sessionID)
            }
        }

        await session.setDisconnectHandler { [weak self] in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.suppressedDisconnectSessionIDs.remove(sessionID) != nil {
                    return
                }
                await self.disconnect()
            }
        }

        await session.setConfigUpdateHandler { [weak self] in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self, let session = self.directSession else { return }
                guard self.sessionIdentity(session) == sessionID else { return }
                await self.syncSessionMetadata(from: session)
            }
        }

        await session.setPermissionHandler { [weak self] request in
            guard let self else { return false }
            // @Sendable 闭包跨隔离 await MainActor 方法，自动 hop 回主线程挂起等待
            return await self.requestPermission(request)
        }
    }

    private func handleSessionUpdate(_ update: SessionUpdate, sessionID: ObjectIdentifier) {
        guard let directSession else { return }
        guard sessionIdentity(directSession) == sessionID else { return }
        guard let event = AgentStreamEvent.from(update) else { return }
        state.accumulatedEvents.append(event)
        eventContinuation.yield(.streamUpdate(event))
    }

    // MARK: - 辅助

    private func sessionIdentity(_ session: any DirectAgentSessionType) -> ObjectIdentifier {
        ObjectIdentifier(session as AnyObject)
    }

    private func suppressNextDisconnectCallback(for session: any DirectAgentSessionType) {
        suppressedDisconnectSessionIDs.insert(sessionIdentity(session))
    }

    /// 将当前累计的流式输出整理成 assistant 消息。
    @discardableResult
    private func emitAssistantMessageIfNeeded(
        source: MessageSource,
        fallbackContent: String? = nil,
        allowEmptyContent: Bool = false
    ) -> Bool {
        let thinkingText = state.accumulatedEvents.compactMap { event -> String? in
            if case .thinking(let text) = event { return text }
            return nil
        }.joined()

        let streamedText = state.accumulatedEvents.compactMap { event -> String? in
            if case .text(let text) = event { return text }
            return nil
        }.joined()

        let content: String
        if !streamedText.isEmpty {
            content = streamedText
        } else if let fallbackContent {
            content = fallbackContent
        } else {
            content = ""
        }

        guard allowEmptyContent || !content.isEmpty || !thinkingText.isEmpty else {
            return false
        }

        let assistantMsg = Message(
            role: .assistant,
            content: content,
            reasoningContent: thinkingText.isEmpty ? nil : thinkingText,
            source: source
        )
        eventContinuation.yield(.messageReady(assistantMsg))
        state.accumulatedEvents = []
        return true
    }
}
