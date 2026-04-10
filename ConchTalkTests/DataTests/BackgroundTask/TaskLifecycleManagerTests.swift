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
}
