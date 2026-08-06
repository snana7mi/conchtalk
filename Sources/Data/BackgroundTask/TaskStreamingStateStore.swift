/// 文件说明：TaskStreamingStateStore，per-server 流式状态快照与 observer 分发。
import Foundation

// MARK: - TaskStreamingState

/// 每个会话的流式状态快照（内存），供 observer 回调推送给前台 ViewModel。
nonisolated struct TaskStreamingState {
    var activeReasoningText: String = ""
    var activeContentText: String = ""
    var liveToolOutput: String? = nil
    var isStreaming: Bool = false
    var isReasoningActive: Bool = false
    var pendingToolCall: ToolCall? = nil
    /// 与 pendingToolCall 并存：承载本次确认的预览/建议规则，供审批卡片渲染。
    var pendingConfirmationRequest: ConfirmationRequest? = nil
    /// needsConfirmation 超时用绝对时间戳（非 Timer），
    /// App 被挂起后 Timer 不走，恢复时用 deadline 判定是否已过期。
    var confirmationDeadline: Date? = nil
    /// 最新中间消息（每个 agentic loop 轮次结束时设置）。
    /// ChatViewModel 通过 message ID 去重，确保每条消息只追加一次。
    var latestIntermediateMessage: Message? = nil
    /// 上下文正在压缩中。
    var isContextCompressing: Bool = false
    /// 编码代理流式事件（已解析）。
    var agentStreamEvents: [AgentStreamEvent] = []
    /// 是否正在执行编码代理。
    var isAgentExecuting: Bool = false
    /// AI 建议连接编码代理，等待用户选择连接模式。
    var pendingAgentConnection: Bool = false
    /// AI 建议的偏好代理类型（如 "opencode"），用于自动匹配跳过选择步骤。
    var preferredAgentType: String? = nil
    /// AI 从对话中提取的工作目录路径。
    var agentCwd: String? = nil
    /// AI 通过 list_directory 获取的目录列表（供浏览器使用）。
    var agentDirectories: [String]? = nil
    /// 目录列表对应的 home 路径。
    var agentHomePath: String? = nil
    /// 当前正在执行的任务 ID（== 触发它的用户消息 ID，由 enqueueTask 的 taskID 贯通保证）。
    /// 默认 nil，所有既有构造点向后兼容。
    var currentTaskID: UUID? = nil
}

// MARK: - TaskStreamingStateStore

/// TaskStreamingStateStore：
/// 维护 per-server 流式状态快照、observer 注册/注销、coalesced 通知分发。
/// 仅负责 observer 回调推送，不处理本地推送通知（由 TaskExecutionCoordinator 负责）。
@MainActor
final class TaskStreamingStateStore {
    private(set) var streamingStates: [UUID: TaskStreamingState] = [:]
    private var stateObservers: [UUID: (TaskStreamingState) -> Void] = [:]
    private var pendingNotifyIDs: Set<UUID> = []
    private var coalesceTask: Task<Void, Never>?

    // MARK: - State Lifecycle

    /// 初始化服务器任务的流式状态。
    func initState(for serverID: UUID, state: TaskStreamingState = TaskStreamingState()) {
        streamingStates[serverID] = state
    }

    /// 获取当前状态快照。
    func state(for serverID: UUID) -> TaskStreamingState? {
        streamingStates[serverID]
    }

    /// 通过闭包更新状态。
    func updateState(for serverID: UUID, update: (inout TaskStreamingState) -> Void) {
        guard var state = streamingStates[serverID] else { return }
        update(&state)
        streamingStates[serverID] = state
    }

    /// 移除服务器状态及其 observer。
    func removeState(for serverID: UUID) {
        streamingStates.removeValue(forKey: serverID)
        stateObservers.removeValue(forKey: serverID)
    }

    // MARK: - Observer

    /// 注册/注销状态观察者。
    /// - Parameters:
    ///   - serverID: 服务器 ID。
    ///   - emitCurrent: 注册后立即推送当前状态快照。
    ///   - callback: 观察回调；传 nil 注销。
    func setObserver(
        for serverID: UUID,
        emitCurrent: Bool = false,
        callback: ((TaskStreamingState) -> Void)?
    ) {
        stateObservers[serverID] = callback
        if emitCurrent, let callback, let state = streamingStates[serverID] {
            callback(state)
        }
    }

    /// 检查是否有 observer。
    func hasObserver(for serverID: UUID) -> Bool {
        stateObservers[serverID] != nil
    }

    /// 获取 observer 闭包引用（用于 cleanup 时提前捕获，防止后续清除丢失）。
    func observer(for serverID: UUID) -> ((TaskStreamingState) -> Void)? {
        stateObservers[serverID]
    }

    // MARK: - Notification

    /// 流式场景专用：标记脏，合并到下一帧推送（~16ms）。
    /// 交互类事件（审批、选择等）应直接调用 notifyObserver，不经过此方法。
    func scheduleNotify(for serverID: UUID) {
        pendingNotifyIDs.insert(serverID)
        guard coalesceTask == nil else { return }
        coalesceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(16))
            guard let self else { return }
            let ids = self.pendingNotifyIDs
            self.pendingNotifyIDs.removeAll()
            self.coalesceTask = nil
            for id in ids {
                self.notifyObserver(for: id)
            }
        }
    }

    /// 立即推送状态给 observer（仅 observer 回调，不含本地通知逻辑）。
    func notifyObserver(for serverID: UUID) {
        guard let state = streamingStates[serverID],
              let observer = stateObservers[serverID] else { return }
        observer(state)
    }
}
