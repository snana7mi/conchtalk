/// 文件说明：TaskExecutionCoordinator，编排 AI 任务的排队、执行、流式回调和生命周期管理。
import Foundation

/// TaskExecutionCoordinator：
/// App 级任务执行编排层，负责：
/// 1. 任务排队与 FIFO 调度（per-server 隔离）
/// 2. 执行上下文构建（via TaskExecutionContextFactory）
/// 3. 流式回调绑定与状态同步
/// 4. 工具审批与代理连接的挂起-恢复-超时流程
/// 5. 完成/取消/错误的善后处理
/// 6. 队列排空与下一任务启动
@MainActor @Observable
final class TaskExecutionCoordinator {

    // MARK: - Event Stream

    /// 任务执行事件流，供上层观察者（如 ChatViewModel）消费。
    let eventStream: AsyncStream<TaskExecutionEvent>

    /// 事件流 continuation，用于在执行过程中 yield 事件。
    private let eventContinuation: AsyncStream<TaskExecutionEvent>.Continuation

    // MARK: - Owned Components

    /// per-server FIFO 排队管理。
    let taskQueue: PerServerTaskQueue

    /// 流式状态快照存储与 observer 分发。
    let stateStore: TaskStreamingStateStore

    /// 任务生命周期管理（注册、取消、清理）。
    let lifecycleManager: TaskLifecycleManager

    /// 消息持久化仓储。
    private let messageRepository: ChatMessageRepository

    // MARK: - Dependencies

    /// 上下文工厂（构建 server context、tool registry、permission）。
    private let contextFactory: TaskExecutionContextFactory

    /// AI 服务。
    private let aiService: AIServiceProtocol

    /// 上下文组装器（可选）。
    private let contextBuilder: ContextBuilder?

    /// 上下文压缩器（可选）。
    private let contextCompactor: ContextCompactor?

    /// 后台保活。
    let keepAlive: BackgroundKeepAlive

    /// Live Activity 管理器（第一梯队保活）。
    let liveActivity = LiveActivityManager()

    /// 通知服务。
    private let notificationService: NotificationService

    /// subagent 角色注册表（供子 agent 编排器按名查找角色定义）。
    private let subagentRegistry: SubagentRegistry

    /// App 是否在前台。
    var isAppInForeground: Bool = true

    /// 有活跃任务的服务器 ID（委托给 lifecycleManager）。
    var activeTaskServerIDs: Set<UUID> {
        lifecycleManager.activeTaskServerIDs
    }

    // MARK: - Init

    init(
        taskQueue: PerServerTaskQueue,
        stateStore: TaskStreamingStateStore,
        lifecycleManager: TaskLifecycleManager,
        messageRepository: ChatMessageRepository,
        contextFactory: TaskExecutionContextFactory,
        aiService: AIServiceProtocol,
        contextBuilder: ContextBuilder? = nil,
        contextCompactor: ContextCompactor? = nil,
        keepAlive: BackgroundKeepAlive,
        notificationService: NotificationService,
        subagentRegistry: SubagentRegistry
    ) {
        let (stream, continuation) = AsyncStream.makeStream(of: TaskExecutionEvent.self)
        self.eventStream = stream
        self.eventContinuation = continuation
        self.taskQueue = taskQueue
        self.stateStore = stateStore
        self.lifecycleManager = lifecycleManager
        self.messageRepository = messageRepository
        self.contextFactory = contextFactory
        self.aiService = aiService
        self.contextBuilder = contextBuilder
        self.contextCompactor = contextCompactor
        self.keepAlive = keepAlive
        self.notificationService = notificationService
        self.subagentRegistry = subagentRegistry
    }

    deinit {
        eventContinuation.finish()
    }

    // MARK: - Public API: Background Keep Alive

    /// 进入后台时申请短时保活。
    func beginBackgroundKeepAlive() {
        guard !lifecycleManager.activeTaskServerIDs.isEmpty else { return }
        keepAlive.beginBackgroundKeepAlive()
    }

    /// 结束短时保活任务（幂等）。
    func endBackgroundKeepAlive() {
        keepAlive.endBackgroundKeepAlive()
    }

    // MARK: - Public API: Queue Access

    /// 取消指定排队任务。
    func cancelQueuedTask(serverID: UUID, taskID: UUID) {
        taskQueue.cancel(serverID: serverID, taskID: taskID)
    }

    // MARK: - Public API: Enqueue

    /// 将指令排入队列；若该服务器当前无活跃任务，则立即启动。
    func enqueueTask(
        serverID: UUID,
        text: String,
        server: Server,
        messages: [Message],
        attachments: [FileAttachment] = []
    ) {
        let queued = QueuedTask(serverID: serverID, text: text, attachments: attachments)
        taskQueue.enqueue(queued)
        if !lifecycleManager.hasActiveTask(for: serverID) {
            dequeueAndExecuteNext(serverID: serverID, messages: messages, server: server)
        }
    }

    // MARK: - Public API: Cancel

    /// 取消指定服务器的任务。
    func cancelTask(for serverID: UUID) {
        cleanupContinuations(for: serverID)
        lifecycleManager.cancelTask(for: serverID)
    }

    /// 取消指定服务器的任务并等待其完成。
    func cancelAndWait(for serverID: UUID) async {
        cleanupContinuations(for: serverID)
        await lifecycleManager.cancelAndWait(for: serverID) { [weak self] in
            self?.cleanupTask(serverID: serverID)
        }
    }

    /// 取消指定服务器的所有任务，等待进入终态后返回。
    @discardableResult
    func cancelTasks(forServer serverID: UUID) async -> [UUID] {
        await lifecycleManager.cancelTasks(
            forServer: serverID,
            onPreCancel: { [weak self] sid in
                self?.cleanupContinuations(for: sid)
            },
            onForceCleanup: { [weak self] sid in
                self?.cleanupTask(serverID: sid)
            }
        )
    }

    // MARK: - Public API: Query

    /// 查询是否有活跃任务。
    func hasActiveTask(for serverID: UUID) -> Bool {
        lifecycleManager.hasActiveTask(for: serverID)
    }

    // MARK: - Public API: Observer

    /// 注册/注销状态观察者。
    func setObserver(
        for serverID: UUID,
        emitCurrent: Bool = true,
        callback: ((TaskStreamingState) -> Void)?
    ) {
        stateStore.setObserver(for: serverID, callback: callback)
        if emitCurrent, let callback, let state = stateStore.state(for: serverID) {
            let didReconcile = reconcileExpired(for: serverID)
            if !didReconcile {
                callback(stateStore.state(for: serverID) ?? state)
            }
        }
    }

    // MARK: - Public API: Approval

    /// 同意当前待审批工具调用。
    func approveToolCall(for serverID: UUID) {
        reconcileExpiredApproval(for: serverID)
        resolveApprovalContinuation(for: serverID, result: .approved)
        stateStore.updateState(for: serverID) {
            $0.pendingToolCall = nil
            $0.confirmationDeadline = nil
        }
        notifyStateChange(for: serverID)
    }

    /// 拒绝当前待审批工具调用。
    func denyToolCall(for serverID: UUID) {
        reconcileExpiredApproval(for: serverID)
        resolveApprovalContinuation(for: serverID, result: .denied)
        stateStore.updateState(for: serverID) {
            $0.pendingToolCall = nil
            $0.confirmationDeadline = nil
        }
        notifyStateChange(for: serverID)
    }

    /// 外部解决 Agent 连接模式选择。
    func resolveAgentConnection(for serverID: UUID, with result: AgentConnectionResult) {
        resolveAgentConnectionContinuation(for: serverID, result: result)
        stateStore.updateState(for: serverID) {
            $0.pendingAgentConnection = false
            $0.preferredAgentType = nil
            $0.agentCwd = nil
            $0.agentDirectories = nil
            $0.agentHomePath = nil
        }
    }

    // MARK: - Public API: Foreground Resume

    /// App 从后台恢复时调用，reconcile 过期审批和选择。
    func onForegroundResume() {
        keepAlive.endBackgroundKeepAlive()
        for serverID in lifecycleManager.activeServerIDs {
            let hadPendingTool = stateStore.state(for: serverID)?.pendingToolCall != nil
            reconcileExpired(for: serverID)
            let hasPendingTool = stateStore.state(for: serverID)?.pendingToolCall != nil
            if hadPendingTool && !hasPendingTool {
                notifyStateChange(for: serverID)
            }
        }
    }

    // MARK: - Internal: Dequeue & Execute

    /// 从队列取出下一条指令并启动执行；失败时继续尝试下一条。
    private func dequeueAndExecuteNext(serverID: UUID, messages: [Message], server: Server) {
        guard let next = taskQueue.dequeue(for: serverID) else { return }
        do {
            try startTask(
                serverID: serverID,
                text: next.text,
                messages: messages,
                server: server,
                attachments: next.attachments
            )
        } catch {
            // 启动失败（如 alreadyRunning），跳过并尝试下一条
            dequeueAndExecuteNext(serverID: serverID, messages: messages, server: server)
        }
    }

    /// 启动任务执行。
    private func startTask(
        serverID: UUID,
        text: String,
        messages: [Message],
        server: Server,
        attachments: [FileAttachment] = []
    ) throws {
        guard !lifecycleManager.hasActiveTask(for: serverID) else {
            throw BackgroundTaskError.alreadyRunning
        }

        // 初始化流式状态
        stateStore.initState(for: serverID, state: TaskStreamingState(isStreaming: true))

        let task = Task { [weak self] in
            guard let self else { return }
            await self.executeTask(
                serverID: serverID,
                text: text,
                messages: messages,
                server: server,
                attachments: attachments
            )
            // 任务完成后自动启动下一条排队指令
            await self.drainQueueAfterTaskCompletion(serverID: serverID, server: server)
        }

        lifecycleManager.registerTask(BackgroundTask(
            task: task,
            serverID: serverID,
            serverName: server.name,
            serverIconData: FlagImageRenderer.resolveServerIconData(server: server, size: 300)
        ))
    }

    // MARK: - Internal: Task Execution

    private func executeTask(
        serverID: UUID,
        text: String,
        messages: [Message],
        server: Server,
        attachments: [FileAttachment] = []
    ) async {
        defer {
            cleanupTask(serverID: serverID)
        }

        // 获取 SSH 客户端
        guard let sshClient = contextFactory.getClient(for: serverID) else {
            try? await messageRepository.appendSystemMessage(
                String(localized: "Error: \(SSHError.notConnected.localizedDescription)",
                       bundle: LanguageSettings.currentBundle),
                type: .error,
                toServer: serverID
            )
            eventContinuation.yield(.failed(serverID: serverID, error: SSHError.notConnected))
            return
        }

        // 解析权限
        let effectivePermissionLevel = contextFactory.resolvePermissionLevel(server: server)
        let localizedTexts = ExecuteNaturalLanguageCommandUseCase.LocalizedTexts(
            userRejectedCommand: "User rejected this command"
        )

        // 构建任务级工具注册表
        let effectiveToolRegistry = contextFactory.makeTaskToolRegistry(serverID: serverID)

        // 创建用例
        let useCase = ExecuteNaturalLanguageCommandUseCase(
            aiService: aiService,
            sshClient: sshClient,
            toolRegistry: effectiveToolRegistry,
            serverID: serverID,
            permissionLevel: effectivePermissionLevel,
            localizedTexts: localizedTexts
        )

        useCase.attachments = attachments
        useCase.serverName = server.name
        useCase.contextBuilder = contextBuilder
        useCase.contextCompactor = contextCompactor

        // 构建服务器上下文
        let serverContext = await contextFactory.buildServerContext(
            serverID: serverID,
            server: server,
            userInput: text
        )

        // 注入 subagent 编排器：复用主审批通道（parentConfirm = handleToolCallConfirmation），
        // 并行确认经 SubagentApprovalGate 串行化，避免 per-server 单槽 continuation 互相覆盖。
        let subagentApprovalGate = SubagentApprovalGate()
        useCase.subagentRunner = SubagentRunner(
            aiService: aiService,
            sshClient: sshClient,
            baseToolRegistry: effectiveToolRegistry,
            registry: subagentRegistry,
            serverID: serverID,
            permissionLevel: effectivePermissionLevel,
            serverContext: serverContext,
            approvalGate: subagentApprovalGate,
            parentConfirm: { [weak self] call in
                guard let self else { return .denied }
                return await self.handleToolCallConfirmation(serverID: serverID, toolCall: call)
            },
            maxConcurrent: 2
        )

        // 绑定回调
        bindUseCaseCallbacks(useCase: useCase, serverID: serverID)

        // 执行 agentic loop
        do {
            let filteredMessages = messages.filter { !$0.isLoading }
            // 直接 await：useCase 是 nonisolated，本就在 MainActor 之外执行，无需 Task.detached；
            // 而 detached 会切断结构化并发的取消传播——外层 Task 被取消时，detached 子任务收不到
            // 取消标志，AI/SSH 实际工作仍会继续跑。直接 await 让取消正确传到 execute 内部。
            let resultMessages = try await useCase.execute(
                userMessage: text,
                conversationHistory: filteredMessages,
                serverContext: serverContext
            )

            guard lifecycleManager.hasActiveTask(for: serverID) else { return }

            // 持久化结果消息
            try? await messageRepository.appendMessages(resultMessages, toServer: serverID)
            eventContinuation.yield(.completed(serverID: serverID, resultMessages: resultMessages))

            // 后处理
            if let bgTask = lifecycleManager.task(for: serverID) {
                await postProcessTask(
                    serverID: serverID,
                    resultMessages: resultMessages,
                    hadWriteOperations: useCase.hadWriteOperations,
                    serverName: bgTask.serverName,
                    serverIconData: bgTask.serverIconData
                )
            }
        } catch is CancellationError {
            print("[TEC] Task cancelled for server \(serverID)")
            guard lifecycleManager.hasActiveTask(for: serverID) else { return }

            // 保存部分消息
            if let state = stateStore.state(for: serverID) {
                let partialContent = state.activeContentText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !partialContent.isEmpty {
                    let partialMsg = Message(
                        role: .assistant,
                        content: partialContent,
                        reasoningContent: state.activeReasoningText.isEmpty ? nil : state.activeReasoningText
                    )
                    try? await messageRepository.appendMessage(partialMsg, toServer: serverID)
                }
            }
            eventContinuation.yield(.cancelled(serverID: serverID))
        } catch {
            guard lifecycleManager.hasActiveTask(for: serverID) else { return }
            print("[TEC] Task error for server \(serverID): \(error)")
            try? await messageRepository.appendSystemMessage(
                String(localized: "Error: \(error.localizedDescription)",
                       bundle: LanguageSettings.currentBundle),
                type: .error,
                toServer: serverID
            )
            eventContinuation.yield(.failed(serverID: serverID, error: error))
        }
    }

    // MARK: - Internal: Callback Binding

    /// 将流式回调绑定到用例上，更新 stateStore 并分发通知。
    private func bindUseCaseCallbacks(
        useCase: ExecuteNaturalLanguageCommandUseCase,
        serverID: UUID
    ) {
        useCase.onToolCallNeedsConfirmation = { [weak self] toolCall in
            guard let self else { return .denied }
            return await self.handleToolCallConfirmation(serverID: serverID, toolCall: toolCall)
        }

        useCase.onAgentConnectionSuggested = { [weak self] preferredAgent, cwd, directories, homePath in
            guard let self else { return .cancelled }
            return await self.handleAgentConnectionRequest(
                serverID: serverID,
                preferredAgent: preferredAgent,
                cwd: cwd,
                directories: directories,
                homePath: homePath
            )
        }

        useCase.onReasoningUpdate = { [weak self] accumulated in
            guard let self, self.lifecycleManager.hasActiveTask(for: serverID) else { return }
            self.stateStore.updateState(for: serverID) {
                $0.activeReasoningText = accumulated
                $0.isReasoningActive = true
            }
            self.stateStore.scheduleNotify(for: serverID)
            self.eventContinuation.yield(.reasoningUpdate(accumulated))
        }

        useCase.onContentUpdate = { [weak self] accumulated in
            guard let self, self.lifecycleManager.hasActiveTask(for: serverID) else { return }
            self.stateStore.updateState(for: serverID) {
                $0.activeContentText = accumulated
                $0.isReasoningActive = false
            }
            self.stateStore.scheduleNotify(for: serverID)
            self.eventContinuation.yield(.contentUpdate(accumulated))
        }

        useCase.onAgentStreamEvents = { [weak self] events in
            guard let self, self.lifecycleManager.hasActiveTask(for: serverID) else { return }
            self.stateStore.updateState(for: serverID) {
                $0.agentStreamEvents.append(contentsOf: events)
                if let last = events.last {
                    if case .completed = last {
                        $0.isAgentExecuting = false
                    } else {
                        $0.isAgentExecuting = true
                    }
                }
            }
            self.stateStore.scheduleNotify(for: serverID)
            self.eventContinuation.yield(.agentStreamEvents(events))
        }

        useCase.onToolOutputUpdate = { [weak self] output in
            guard let self, self.lifecycleManager.hasActiveTask(for: serverID) else { return }
            self.stateStore.updateState(for: serverID) { $0.liveToolOutput = output }
            self.stateStore.scheduleNotify(for: serverID)
            self.eventContinuation.yield(.toolOutputUpdate(output))
        }

        useCase.onContextCompressing = { [weak self] active in
            guard let self, self.lifecycleManager.hasActiveTask(for: serverID) else { return }
            self.stateStore.updateState(for: serverID) { $0.isContextCompressing = active }
            self.notifyStateChange(for: serverID)
            self.eventContinuation.yield(.contextCompressing(active))
        }

        useCase.onIntermediateMessage = { [weak self] message in
            guard let self, self.lifecycleManager.hasActiveTask(for: serverID) else { return }
            Task {
                try? await self.messageRepository.appendMessage(message, toServer: serverID)
            }
            self.stateStore.updateState(for: serverID) {
                $0.latestIntermediateMessage = message
                $0.activeContentText = ""
                $0.activeReasoningText = ""
                $0.isReasoningActive = false
                $0.liveToolOutput = nil
                $0.agentStreamEvents = []
            }
            self.notifyStateChange(for: serverID)
            self.eventContinuation.yield(.intermediateMessage(message))

            if !self.isAppInForeground {
                self.keepAlive.endBackgroundKeepAlive()
            }
        }
    }

    // MARK: - Internal: Tool Call Confirmation

    private func handleToolCallConfirmation(
        serverID: UUID,
        toolCall: ToolCall
    ) async -> CommandApproval {
        guard lifecycleManager.hasActiveTask(for: serverID) else { return .denied }

        // 更新 stateStore
        let deadline = Date().addingTimeInterval(Self.defaultApprovalTimeoutSeconds)
        stateStore.updateState(for: serverID) {
            $0.pendingToolCall = toolCall
            $0.confirmationDeadline = deadline
        }
        notifyStateChange(for: serverID)
        eventContinuation.yield(.toolCallNeedsConfirmation(toolCall, deadline: deadline))

        // 等待审批
        let result = await waitForApproval(serverID: serverID)

        // 清理状态
        stateStore.updateState(for: serverID) {
            $0.pendingToolCall = nil
            $0.confirmationDeadline = nil
        }

        return result
    }

    // MARK: - Internal: Agent Connection

    private func handleAgentConnectionRequest(
        serverID: UUID,
        preferredAgent: String?,
        cwd: String?,
        directories: [String]?,
        homePath: String?
    ) async -> AgentConnectionResult {
        guard lifecycleManager.hasActiveTask(for: serverID) else { return .cancelled }

        // 更新 stateStore
        stateStore.updateState(for: serverID) {
            $0.pendingAgentConnection = true
            $0.preferredAgentType = preferredAgent
            $0.agentCwd = cwd
            $0.agentDirectories = directories
            $0.agentHomePath = homePath
        }
        notifyStateChange(for: serverID)
        eventContinuation.yield(.agentConnectionSuggested(
            preferredAgent: preferredAgent, cwd: cwd, directories: directories, homePath: homePath
        ))

        // 等待连接决策
        let result = await waitForAgentConnection(serverID: serverID)

        // 清理状态
        stateStore.updateState(for: serverID) {
            $0.pendingAgentConnection = false
            $0.preferredAgentType = nil
            $0.agentCwd = nil
            $0.agentDirectories = nil
            $0.agentHomePath = nil
        }

        return result
    }

    // MARK: - Internal: Reconcile

    /// 检查并处理过期的审批请求（工具调用审批部分）。
    @discardableResult
    private func reconcileExpiredApproval(for serverID: UUID) -> Bool {
        guard approvalContinuations[serverID] != nil,
              let deadline = approvalDeadlines[serverID],
              Date() >= deadline else { return false }
        resolveApprovalContinuation(for: serverID, result: .denied)
        stateStore.updateState(for: serverID) {
            $0.pendingToolCall = nil
            $0.confirmationDeadline = nil
        }
        notifyStateChange(for: serverID)
        return true
    }

    /// 统一 reconcile：检查所有过期的挂起请求。
    @discardableResult
    private func reconcileExpired(for serverID: UUID) -> Bool {
        var resolved = false
        // 检查过期审批
        if approvalContinuations[serverID] != nil,
           let deadline = approvalDeadlines[serverID],
           Date() >= deadline {
            resolveApprovalContinuation(for: serverID, result: .denied)
            stateStore.updateState(for: serverID) {
                $0.pendingToolCall = nil
                $0.confirmationDeadline = nil
            }
            resolved = true
        }
        // 检查过期代理连接
        if agentConnectionContinuations[serverID] != nil,
           let deadline = agentConnectionDeadlines[serverID],
           Date() >= deadline {
            resolveAgentConnectionContinuation(for: serverID, result: .cancelled)
            stateStore.updateState(for: serverID) {
                $0.pendingAgentConnection = false
                $0.preferredAgentType = nil
                $0.agentCwd = nil
                $0.agentDirectories = nil
                $0.agentHomePath = nil
            }
            resolved = true
        }
        if resolved {
            notifyStateChange(for: serverID)
        }
        return resolved
    }

    // MARK: - Internal: Queue Drain

    /// 任务完成后，从持久化层加载最新消息，并启动下一条排队指令。
    private func drainQueueAfterTaskCompletion(serverID: UUID, server: Server) async {
        guard !taskQueue.isEmpty(for: serverID) else { return }
        guard !lifecycleManager.hasActiveTask(for: serverID) else { return }
        let latestMessages: [Message]
        do {
            latestMessages = try await messageRepository.reloadMessages(forServer: serverID)
        } catch {
            print("[TEC] drainQueue: 加载消息失败 \(error)")
            latestMessages = []
        }
        dequeueAndExecuteNext(serverID: serverID, messages: latestMessages, server: server)
    }

    // MARK: - Internal: Cleanup

    private func cleanupTask(serverID: UUID) {
        cleanupContinuations(for: serverID)
        lifecycleManager.cleanupTask(
            for: serverID,
            stateStore: stateStore,
            keepAlive: keepAlive
        )
    }

    // MARK: - Internal: Notification

    private func notifyStateChange(for serverID: UUID) {
        stateStore.notifyObserver(for: serverID)

        guard let state = stateStore.state(for: serverID) else { return }

        let needsNotification = !isAppInForeground || !stateStore.hasObserver(for: serverID)
        guard needsNotification else { return }

        guard let bgTask = lifecycleManager.task(for: serverID) else { return }

        if let toolCall = state.pendingToolCall {
            notificationService.sendApprovalNotification(
                toolName: toolCall.explanation.isEmpty ? toolCall.toolName : toolCall.explanation,
                serverName: bgTask.serverName,
                serverIconData: bgTask.serverIconData,
                serverID: serverID
            )
        }
    }

    // MARK: - Post Processing

    /// 任务结束后善后：profile 刷新、通知发送。
    private func postProcessTask(
        serverID: UUID,
        resultMessages: [Message],
        hadWriteOperations: Bool,
        serverName: String,
        serverIconData: Data?
    ) async {
        // 对话中有写操作时，后台刷新系统 profile
        if hadWriteOperations {
            Task { @MainActor in
                await contextFactory.sshSessionManager.refreshSystemProfile(for: serverID)
            }
        }

        // 发送 AI 回复通知（用户不在页面时）
        let needsNotification = !isAppInForeground || !stateStore.hasObserver(for: serverID)
        if needsNotification,
           let lastAssistant = resultMessages.last(where: { $0.role == .assistant }),
           !lastAssistant.content.isEmpty {
            let preview = String(lastAssistant.content.prefix(100))
            notificationService.sendReplyNotification(
                serverName: serverName,
                serverIconData: serverIconData,
                messagePreview: preview,
                serverID: serverID
            )
        }
    }

    // MARK: - Approval & Agent Connection

    /// 工具审批 continuation（keyed by serverID）。
    private var approvalContinuations: [UUID: CheckedContinuation<CommandApproval, Never>] = [:]
    /// 工具审批超时任务句柄。
    private var approvalTimeoutTasks: [UUID: Task<Void, Never>] = [:]
    /// 工具审批绝对截止时间（Layer 2：应对设备挂起时 Task.sleep 不触发的情况）。
    private var approvalDeadlines: [UUID: Date] = [:]

    /// 代理连接 continuation（keyed by serverID）。
    private var agentConnectionContinuations: [UUID: CheckedContinuation<AgentConnectionResult, Never>] = [:]
    /// 代理连接超时任务句柄。
    private var agentConnectionTimeoutTasks: [UUID: Task<Void, Never>] = [:]
    /// 代理连接绝对截止时间（Layer 2）。
    private var agentConnectionDeadlines: [UUID: Date] = [:]

    /// 默认审批超时时长（秒）。
    private static let defaultApprovalTimeoutSeconds: TimeInterval = 300

    /// 挂起等待工具审批结果。超时自动拒绝。
    private func waitForApproval(
        serverID: UUID,
        timeoutSeconds: TimeInterval? = nil
    ) async -> CommandApproval {
        let timeout = timeoutSeconds ?? Self.defaultApprovalTimeoutSeconds

        return await withCheckedContinuation { continuation in
            self.approvalContinuations[serverID] = continuation
            self.approvalDeadlines[serverID] = Date().addingTimeInterval(timeout)

            // Layer 1: 超时任务（app 活跃时触发）
            self.approvalTimeoutTasks[serverID] = Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                guard !Task.isCancelled else { return }
                self?.resolveApprovalContinuation(for: serverID, result: .denied)
            }
        }
    }

    /// 唯一的 approval continuation resume 入口（one-shot）。
    private func resolveApprovalContinuation(for serverID: UUID, result: CommandApproval) {
        guard let continuation = approvalContinuations.removeValue(forKey: serverID) else { return }
        approvalTimeoutTasks.removeValue(forKey: serverID)?.cancel()
        approvalDeadlines.removeValue(forKey: serverID)
        continuation.resume(returning: result)
    }

    /// 挂起等待代理连接结果。超时自动取消。
    private func waitForAgentConnection(
        serverID: UUID,
        timeoutSeconds: TimeInterval? = nil
    ) async -> AgentConnectionResult {
        let timeout = timeoutSeconds ?? Self.defaultApprovalTimeoutSeconds

        return await withCheckedContinuation { continuation in
            self.agentConnectionContinuations[serverID] = continuation
            self.agentConnectionDeadlines[serverID] = Date().addingTimeInterval(timeout)

            // Layer 1: 超时任务（app 活跃时触发）
            self.agentConnectionTimeoutTasks[serverID] = Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                guard !Task.isCancelled else { return }
                self?.resolveAgentConnectionContinuation(for: serverID, result: .cancelled)
            }
        }
    }

    /// 唯一的 agent connection continuation resume 入口（one-shot）。
    private func resolveAgentConnectionContinuation(for serverID: UUID, result: AgentConnectionResult) {
        guard let continuation = agentConnectionContinuations.removeValue(forKey: serverID) else { return }
        agentConnectionTimeoutTasks.removeValue(forKey: serverID)?.cancel()
        agentConnectionDeadlines.removeValue(forKey: serverID)
        continuation.resume(returning: result)
    }

    /// 清理指定服务器的所有 continuation（以默认值 resume），取消超时任务。
    /// 用于任务取消/结束时防止 continuation 泄漏导致挂起。
    private func cleanupContinuations(for serverID: UUID) {
        // 审批
        if let continuation = approvalContinuations.removeValue(forKey: serverID) {
            approvalTimeoutTasks.removeValue(forKey: serverID)?.cancel()
            approvalDeadlines.removeValue(forKey: serverID)
            continuation.resume(returning: .denied)
        } else {
            approvalTimeoutTasks.removeValue(forKey: serverID)?.cancel()
            approvalDeadlines.removeValue(forKey: serverID)
        }

        // 代理连接
        if let continuation = agentConnectionContinuations.removeValue(forKey: serverID) {
            agentConnectionTimeoutTasks.removeValue(forKey: serverID)?.cancel()
            agentConnectionDeadlines.removeValue(forKey: serverID)
            continuation.resume(returning: .cancelled)
        } else {
            agentConnectionTimeoutTasks.removeValue(forKey: serverID)?.cancel()
            agentConnectionDeadlines.removeValue(forKey: serverID)
        }
    }
}

