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
}

/// TaskLifecycleManager：
/// 管理 AI 任务的启动、取消、等待完成和清理。
@MainActor @Observable
final class TaskLifecycleManager {
    /// 有活跃任务的服务器 ID（供 UI 观察）。
    private(set) var activeTaskServerIDs: Set<UUID> = []

    /// 内部任务存储。
    private var backgroundTasks: [UUID: BackgroundTask] = [:]

    /// cancelAndWait 等待清理完成的 continuation 队列。
    private var cleanupContinuations: [UUID: [CheckedContinuation<Void, Never>]] = [:]

    /// 查询是否有活跃任务。
    func hasActiveTask(for id: UUID) -> Bool { backgroundTasks[id] != nil }

    /// 获取指定服务器的任务元信息。
    func task(for id: UUID) -> BackgroundTask? { backgroundTasks[id] }

    /// 所有活跃任务的服务器 ID。
    var activeServerIDs: [UUID] { Array(backgroundTasks.keys) }

    /// 注册新任务。
    func registerTask(_ task: BackgroundTask) {
        backgroundTasks[task.serverID] = task
        activeTaskServerIDs.insert(task.serverID)
    }

    /// 取消指定服务器的任务（仅取消 Task，不等待清理完成）。
    func cancelTask(for id: UUID) {
        backgroundTasks[id]?.task.cancel()
    }

    /// 取消指定服务器的任务并等待清理完成（含 defer cleanupTask 和持久化）。
    /// 通过 continuation 等待 cleanupTask 完成通知，最多 5 秒超时后强制清理。
    func cancelAndWait(for id: UUID, onForceCleanup: @escaping () -> Void) async {
        guard backgroundTasks[id] != nil else { return }
        backgroundTasks[id]?.task.cancel()

        // 任务已清理则直接返回
        guard backgroundTasks[id] != nil else { return }

        // 通过 continuation 等待 cleanupTask 完成，配合超时兜底
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            cleanupContinuations[id, default: []].append(continuation)

            // 超时兜底：5 秒后若仍未被 cleanupTask resume，则强制清理并 resume
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, let self else { return }
                guard self.backgroundTasks[id] != nil else { return }
                print("[BTM] cancelAndWait: \(id) timed out, force cleanup")
                onForceCleanup()
            }
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
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                self.cleanupContinuations[taskID, default: []].append(continuation)

                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(5))
                    guard !Task.isCancelled, let self else { return }
                    guard self.backgroundTasks[taskID] != nil else { return }
                    print("[BTM] cancelTasks: \(taskID) timed out, force cleanup")
                    onForceCleanup(taskID)
                }
            }
        }
        return taskIDs
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

    /// resume 并移除指定服务器的所有 cleanup continuation。
    private func resumeCleanupContinuations(for id: UUID) {
        guard let continuations = cleanupContinuations.removeValue(forKey: id) else { return }
        for continuation in continuations {
            continuation.resume()
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
