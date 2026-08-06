/// 文件说明：TaskLifecycleManager，AI 任务生命周期管理。
import Foundation

/// BackgroundTaskError：任务生命周期错误。
enum BackgroundTaskError: LocalizedError {
    case alreadyRunning

    var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            return String(localized: "A task is already running. Stop it first.",
                          bundle: LanguageSettings.currentBundle)
        }
    }
}

/// BackgroundTask：任务包装。
struct BackgroundTask {
    let task: Task<Void, Never>
    let serverID: UUID
    let serverName: String
    let serverIconData: Data?
    /// 任务代次：由 registerTask 分配（单调递增），强清 watchdog 用于身份比对，
    /// 防止旧任务的兜底误清同 serverID 的后续新任务。
    var generation: UInt64 = 0
}

/// TaskLifecycleManager：
/// 管理 AI 任务的启动、取消、等待完成和清理。
@MainActor @Observable
final class TaskLifecycleManager {
    /// 有活跃任务的服务器 ID（供 UI 观察）。
    private(set) var activeTaskServerIDs: Set<UUID> = []

    /// 内部任务存储。
    private var backgroundTasks: [UUID: BackgroundTask] = [:]

    /// CleanupWaiter：cancelAndWait / cancelTasks 的等待者——continuation + 对应的兜底 watchdog 句柄。
    private struct CleanupWaiter {
        let continuation: CheckedContinuation<Void, Never>
        let watchdog: Task<Void, Never>
    }

    /// 等待清理完成的等待者队列（替代旧 cleanupContinuations，watchdog 随 continuation 同生命周期管理）。
    private var cleanupWaiters: [UUID: [CleanupWaiter]] = [:]

    /// 强清兜底等待时长（测试注入短值）。
    private let forceCleanupTimeout: Duration

    /// 任务代次计数器：registerTask 时自增分配。
    private var nextGeneration: UInt64 = 0

    init(forceCleanupTimeout: Duration = .seconds(5)) {
        self.forceCleanupTimeout = forceCleanupTimeout
    }

    /// 查询是否有活跃任务。
    func hasActiveTask(for id: UUID) -> Bool { backgroundTasks[id] != nil }

    /// 获取指定服务器的任务元信息。
    func task(for id: UUID) -> BackgroundTask? { backgroundTasks[id] }

    /// 所有活跃任务的服务器 ID。
    var activeServerIDs: [UUID] { Array(backgroundTasks.keys) }

    /// 注册新任务（内部分配代次，调用方无需关心 generation）。
    func registerTask(_ task: BackgroundTask) {
        var registered = task
        nextGeneration += 1
        registered.generation = nextGeneration
        backgroundTasks[task.serverID] = registered
        activeTaskServerIDs.insert(task.serverID)
    }

    /// 取消指定服务器的任务（仅取消 Task，不等待清理完成）。
    func cancelTask(for id: UUID) {
        backgroundTasks[id]?.task.cancel()
    }

    /// 取消指定服务器的任务并等待清理完成（含 defer cleanupTask 和持久化）。
    /// 通过 continuation 等待 cleanupTask 完成通知，超过兜底时长后强制清理。
    func cancelAndWait(for id: UUID, onForceCleanup: @escaping () -> Void) async {
        guard backgroundTasks[id] != nil else { return }
        backgroundTasks[id]?.task.cancel()

        // 任务已清理则直接返回
        guard backgroundTasks[id] != nil else { return }

        // 捕获发起取消时刻的任务代次，watchdog 凭此比对身份
        let expectedGeneration = backgroundTasks[id]?.generation
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let watchdog = makeForceCleanupWatchdog(
                id: id,
                expectedGeneration: expectedGeneration,
                label: "cancelAndWait",
                onForceCleanup: onForceCleanup
            )
            cleanupWaiters[id, default: []].append(
                CleanupWaiter(continuation: continuation, watchdog: watchdog)
            )
        }
    }

    /// 取消指定服务器的所有任务，等待进入终态后返回。返回被取消的服务器 ID 列表。
    @discardableResult
    func cancelTasks(
        forServer serverID: UUID,
        onPreCancel: (UUID) -> Void,
        onForceCleanup: @escaping (UUID) -> Void
    ) async -> [UUID] {
        let taskIDs = backgroundTasks
            .filter { $0.value.serverID == serverID }
            .map(\.key)
        guard !taskIDs.isEmpty else { return [] }

        for taskID in taskIDs {
            onPreCancel(taskID)
            backgroundTasks[taskID]?.task.cancel()
        }

        // 通过 continuation 等待各任务 cleanupTask 完成，配合超时兜底
        for taskID in taskIDs {
            guard self.backgroundTasks[taskID] != nil else { continue }
            let expectedGeneration = self.backgroundTasks[taskID]?.generation
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let watchdog = makeForceCleanupWatchdog(
                    id: taskID,
                    expectedGeneration: expectedGeneration,
                    label: "cancelTasks",
                    onForceCleanup: { onForceCleanup(taskID) }
                )
                self.cleanupWaiters[taskID, default: []].append(
                    CleanupWaiter(continuation: continuation, watchdog: watchdog)
                )
            }
        }
        return taskIDs
    }

    /// 创建强清兜底 watchdog：睡满兜底时长后，仅当「当初被取消的那个任务」仍在册时才强清。
    /// 双保险：① 正常清理路径会在 resume 前取消本 Task；② generation 不符（旧任务已清、
    /// 新任务已注册）时静默退出，绝不动新任务。
    private func makeForceCleanupWatchdog(
        id: UUID,
        expectedGeneration: UInt64?,
        label: String,
        onForceCleanup: @escaping () -> Void
    ) -> Task<Void, Never> {
        Task { @MainActor [weak self, forceCleanupTimeout] in
            try? await Task.sleep(for: forceCleanupTimeout)
            guard !Task.isCancelled, let self else { return }
            guard let current = self.backgroundTasks[id],
                  current.generation == expectedGeneration else { return }
            print("[BTM] \(label): \(id) timed out, force cleanup")
            onForceCleanup()
        }
    }

    /// CLEANUP INVARIANT — this ordering is safety-critical:
    /// 1. Capture observer reference before clearing
    /// 2. Remove from backgroundTasks
    /// 3. Remove from activeTaskServerIDs
    /// 4. Send final state to captured observer
    /// 5. Remove streaming state
    /// 6. Resume cleanup continuations
    ///
    /// 注意：审批 continuation 清理由调用方（TaskExecutionCoordinator）在调用本方法前完成。
    func cleanupTask(
        for id: UUID,
        stateStore: TaskStreamingStateStore,
        keepAlive: BackgroundKeepAlive
    ) {
        // 提前捕获 observer 引用，防止 cancelTask 先行清除导致最终推送丢失
        let capturedObserver = stateStore.observer(for: id)

        guard backgroundTasks.removeValue(forKey: id) != nil else {
            // 任务已移除（幂等），仍需 resume 等待中的 continuation
            resumeCleanupContinuations(for: id)
            return
        }
        activeTaskServerIDs.remove(id)

        // 任务结束，若无其他活跃任务则释放后台保活
        if activeTaskServerIDs.isEmpty {
            keepAlive.endBackgroundKeepAlive()
        }

        // 发送最终通知：isStreaming = false 表示任务已结束。
        // 使用提前捕获的 observer，即使字典已被清除也能推送。
        if let observer = capturedObserver {
            var finalState = stateStore.state(for: id) ?? TaskStreamingState()
            finalState.isStreaming = false
            finalState.isReasoningActive = false
            finalState.isContextCompressing = false
            finalState.pendingToolCall = nil
            finalState.confirmationDeadline = nil
            finalState.pendingAgentConnection = false
            finalState.preferredAgentType = nil
            finalState.agentCwd = nil
            finalState.agentDirectories = nil
            finalState.agentHomePath = nil
            observer(finalState)
        }

        stateStore.removeState(for: id)

        // resume 所有 cancelAndWait / cancelTasks 的等待者
        resumeCleanupContinuations(for: id)
    }

    /// resume 并移除指定服务器的所有 cleanup 等待者，同步取消其兜底 watchdog。
    private func resumeCleanupContinuations(for id: UUID) {
        guard let waiters = cleanupWaiters.removeValue(forKey: id) else { return }
        for waiter in waiters {
            waiter.watchdog.cancel()
            waiter.continuation.resume()
        }
    }

    // MARK: - Test Seam

    /// 测试用：注册一个简化任务。
    func registerTaskForTesting(serverID: UUID, task: Task<Void, Never>) {
        let bt = BackgroundTask(
            task: task,
            serverID: serverID,
            serverName: "test",
            serverIconData: nil
        )
        registerTask(bt)
    }
}
