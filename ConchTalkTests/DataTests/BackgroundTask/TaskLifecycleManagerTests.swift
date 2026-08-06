/// 文件说明：TaskLifecycleManagerTests，验证任务生命周期管理。
import Testing
@testable import ConchTalk
import Foundation

@Suite("TaskLifecycleManager")
@MainActor
struct TaskLifecycleManagerTests {

    @Test("hasActiveTask 反映任务状态")
    func hasActiveTask() {
        let manager = TaskLifecycleManager()
        let id = UUID()
        #expect(!manager.hasActiveTask(for: id))

        let task = Task<Void, Never> { try? await Task.sleep(for: .seconds(10)) }
        manager.registerTaskForTesting(serverID: id, task: task)
        #expect(manager.hasActiveTask(for: id))
        task.cancel()
    }

    @Test("cancelTask 取消任务")
    func cancelTask() {
        let manager = TaskLifecycleManager()
        let id = UUID()
        let task = Task<Void, Never> { try? await Task.sleep(for: .seconds(10)) }
        manager.registerTaskForTesting(serverID: id, task: task)

        manager.cancelTask(for: id)
        #expect(task.isCancelled)
    }

    @Test("registerTask 更新 activeTaskServerIDs")
    func registerUpdatesActiveIDs() {
        let manager = TaskLifecycleManager()
        let id = UUID()
        #expect(manager.activeTaskServerIDs.isEmpty)

        let task = Task<Void, Never> { try? await Task.sleep(for: .seconds(10)) }
        manager.registerTaskForTesting(serverID: id, task: task)
        #expect(manager.activeTaskServerIDs.contains(id))
        task.cancel()
    }

    @Test("task(for:) 返回已注册任务")
    func taskForID() {
        let manager = TaskLifecycleManager()
        let id = UUID()
        #expect(manager.task(for: id) == nil)

        let task = Task<Void, Never> { try? await Task.sleep(for: .seconds(10)) }
        manager.registerTaskForTesting(serverID: id, task: task)
        #expect(manager.task(for: id) != nil)
        #expect(manager.task(for: id)?.serverID == id)
        task.cancel()
    }

    // MARK: - 强清兜底（问题 7）

    /// MainActor 上的计数器，供 onForceCleanup 闭包安全计数。
    @MainActor
    final class ForceCleanupSpy {
        private(set) var count = 0
        func record() { count += 1 }
    }

    @Test("registerTask 分配单调递增的任务代次")
    func registerTask_assignsMonotonicGeneration() {
        let manager = TaskLifecycleManager()
        let id1 = UUID()
        let id2 = UUID()
        let t1 = Task<Void, Never> { try? await Task.sleep(for: .seconds(10)) }
        let t2 = Task<Void, Never> { try? await Task.sleep(for: .seconds(10)) }
        defer { t1.cancel(); t2.cancel() }

        manager.registerTaskForTesting(serverID: id1, task: t1)
        manager.registerTaskForTesting(serverID: id2, task: t2)

        let g1 = manager.task(for: id1)?.generation ?? 0
        let g2 = manager.task(for: id2)?.generation ?? 0
        #expect(g1 > 0)
        #expect(g2 > g1)
    }

    @Test("正常清理后注册的同 serverID 新任务不被兜底误杀")
    func cancelAndWait_normalCleanupDoesNotKillNewTask() async {
        let manager = TaskLifecycleManager(forceCleanupTimeout: .milliseconds(100))
        let stateStore = TaskStreamingStateStore()
        let keepAlive = BackgroundKeepAlive()
        let id = UUID()
        let spy = ForceCleanupSpy()

        manager.registerTaskForTesting(
            serverID: id, task: Task { try? await Task.sleep(for: .seconds(10)) })

        let waitTask = Task { @MainActor in
            await manager.cancelAndWait(for: id) { spy.record() }
        }
        // 让 cancelAndWait 先挂起到 continuation
        try? await Task.sleep(for: .milliseconds(20))
        // 模拟 cleanupTask 正常完成（resume 等待者并取消 watchdog）
        manager.cleanupTask(for: id, stateStore: stateStore, keepAlive: keepAlive)
        await waitTask.value

        // 同 serverID 立即注册新任务（「停止后立刻重发」场景）
        manager.registerTaskForTesting(
            serverID: id, task: Task { try? await Task.sleep(for: .seconds(10)) })

        // 越过兜底时长：若 watchdog 未被取消/身份比对失效，将在此期间误清新任务
        try? await Task.sleep(for: .milliseconds(300))

        #expect(manager.hasActiveTask(for: id))
        #expect(spy.count == 0)
    }

    @Test("cleanupTask 永不发生时兜底强清恰好触发一次")
    func cancelAndWait_timeoutForceCleansStaleTask() async {
        let manager = TaskLifecycleManager(forceCleanupTimeout: .milliseconds(100))
        let stateStore = TaskStreamingStateStore()
        let keepAlive = BackgroundKeepAlive()
        let id = UUID()
        let spy = ForceCleanupSpy()

        manager.registerTaskForTesting(
            serverID: id, task: Task { try? await Task.sleep(for: .seconds(10)) })

        // 与 TaskExecutionCoordinator 的真实接线一致：onForceCleanup 内调 cleanupTask
        await manager.cancelAndWait(for: id) { [weak manager] in
            spy.record()
            manager?.cleanupTask(for: id, stateStore: stateStore, keepAlive: keepAlive)
        }

        #expect(spy.count == 1)
        #expect(!manager.hasActiveTask(for: id))
    }

    @Test("cancelTasks 路径：正常清理后新任务不被误杀")
    func cancelTasks_normalCleanupDoesNotKillNewTask() async {
        let manager = TaskLifecycleManager(forceCleanupTimeout: .milliseconds(100))
        let stateStore = TaskStreamingStateStore()
        let keepAlive = BackgroundKeepAlive()
        let id = UUID()
        let spy = ForceCleanupSpy()

        manager.registerTaskForTesting(
            serverID: id, task: Task { try? await Task.sleep(for: .seconds(10)) })

        let waitTask = Task { @MainActor in
            _ = await manager.cancelTasks(
                forServer: id,
                onPreCancel: { _ in },
                onForceCleanup: { _ in spy.record() }
            )
        }
        try? await Task.sleep(for: .milliseconds(20))
        manager.cleanupTask(for: id, stateStore: stateStore, keepAlive: keepAlive)
        await waitTask.value

        manager.registerTaskForTesting(
            serverID: id, task: Task { try? await Task.sleep(for: .seconds(10)) })
        try? await Task.sleep(for: .milliseconds(300))

        #expect(manager.hasActiveTask(for: id))
        #expect(spy.count == 0)
    }

    @Test("cancelTasks 路径：cleanupTask 永不发生时兜底强清触发")
    func cancelTasks_timeoutForceCleansStaleTask() async {
        let manager = TaskLifecycleManager(forceCleanupTimeout: .milliseconds(100))
        let stateStore = TaskStreamingStateStore()
        let keepAlive = BackgroundKeepAlive()
        let id = UUID()
        let spy = ForceCleanupSpy()

        manager.registerTaskForTesting(
            serverID: id, task: Task { try? await Task.sleep(for: .seconds(10)) })

        _ = await manager.cancelTasks(
            forServer: id,
            onPreCancel: { _ in },
            onForceCleanup: { [weak manager] taskID in
                spy.record()
                manager?.cleanupTask(for: taskID, stateStore: stateStore, keepAlive: keepAlive)
            }
        )

        #expect(spy.count == 1)
        #expect(!manager.hasActiveTask(for: id))
    }
}
