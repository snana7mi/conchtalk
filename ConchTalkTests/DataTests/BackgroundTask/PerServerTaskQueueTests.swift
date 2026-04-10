/// 文件说明：PerServerTaskQueueTests，验证 PerServerTaskQueue 按服务器隔离的 FIFO 排队行为。
import Testing
@testable import ConchTalk
import Foundation

@Suite("PerServerTaskQueue")
@MainActor
struct PerServerTaskQueueTests {

    @Test("dequeue 只返回指定服务器的任务")
    func dequeue_returnsOnlyTasksForRequestedServer() {
        let queue = PerServerTaskQueue()
        let serverA = UUID()
        let serverB = UUID()
        let taskA = QueuedTask(serverID: serverA, text: "task for A")
        let taskB = QueuedTask(serverID: serverB, text: "task for B")

        queue.enqueue(taskA)
        queue.enqueue(taskB)

        let dequeued = queue.dequeue(for: serverA)
        #expect(dequeued?.id == taskA.id)
        #expect(dequeued?.serverID == serverA)

        // serverA 队列已空
        #expect(queue.dequeue(for: serverA) == nil)

        // serverB 的任务不受影响
        let dequeuedB = queue.dequeue(for: serverB)
        #expect(dequeuedB?.id == taskB.id)
    }

    @Test("cancel 移除指定服务器指定任务 ID 的排队任务")
    func cancel_removesQueuedTaskByMessageID() {
        let queue = PerServerTaskQueue()
        let serverID = UUID()
        let taskID = UUID()
        let task = QueuedTask(id: taskID, serverID: serverID, text: "to cancel")
        let kept = QueuedTask(serverID: serverID, text: "to keep")

        queue.enqueue(task)
        queue.enqueue(kept)

        queue.cancel(serverID: serverID, taskID: taskID)

        let tasks = queue.tasks(for: serverID)
        #expect(tasks.count == 1)
        #expect(tasks.first?.id == kept.id)
    }

    @Test("同一服务器内的任务按 FIFO 顺序出队")
    func queuedTasks_preserveFIFOWithinSameServer() {
        let queue = PerServerTaskQueue()
        let serverID = UUID()
        let first = QueuedTask(serverID: serverID, text: "first")
        let second = QueuedTask(serverID: serverID, text: "second")
        let third = QueuedTask(serverID: serverID, text: "third")

        queue.enqueue(first)
        queue.enqueue(second)
        queue.enqueue(third)

        #expect(queue.dequeue(for: serverID)?.id == first.id)
        #expect(queue.dequeue(for: serverID)?.id == second.id)
        #expect(queue.dequeue(for: serverID)?.id == third.id)
        #expect(queue.dequeue(for: serverID) == nil)
    }

    @Test("isEmpty 正确反映指定服务器的队列状态")
    func isEmpty_reflectsPerServerState() {
        let queue = PerServerTaskQueue()
        let serverA = UUID()
        let serverB = UUID()

        #expect(queue.isEmpty(for: serverA))
        #expect(queue.isEmpty(for: serverB))

        queue.enqueue(QueuedTask(serverID: serverA, text: "task"))

        #expect(!queue.isEmpty(for: serverA))
        #expect(queue.isEmpty(for: serverB))
    }

    @Test("tasks 返回指定服务器的所有排队任务快照")
    func tasks_returnsSnapshotForServer() {
        let queue = PerServerTaskQueue()
        let serverID = UUID()

        queue.enqueue(QueuedTask(serverID: serverID, text: "one"))
        queue.enqueue(QueuedTask(serverID: serverID, text: "two"))

        let tasks = queue.tasks(for: serverID)
        #expect(tasks.count == 2)
        #expect(tasks[0].text == "one")
        #expect(tasks[1].text == "two")
    }

    @Test("cancel 对不存在的任务静默忽略")
    func cancel_nonExistentTaskIsNoOp() {
        let queue = PerServerTaskQueue()
        let serverID = UUID()
        queue.enqueue(QueuedTask(serverID: serverID, text: "task"))

        // 取消不存在的 taskID
        queue.cancel(serverID: serverID, taskID: UUID())

        #expect(queue.tasks(for: serverID).count == 1)
    }

    @Test("dequeue 空服务器返回 nil")
    func dequeue_emptyServerReturnsNil() {
        let queue = PerServerTaskQueue()
        #expect(queue.dequeue(for: UUID()) == nil)
    }

    @Test("cancelAll 清空指定服务器的所有排队任务")
    func cancelAll_removesAllTasksForServer() {
        let queue = PerServerTaskQueue()
        let serverA = UUID()
        let serverB = UUID()

        queue.enqueue(QueuedTask(serverID: serverA, text: "a1"))
        queue.enqueue(QueuedTask(serverID: serverA, text: "a2"))
        queue.enqueue(QueuedTask(serverID: serverB, text: "b1"))

        queue.cancelAll(for: serverA)

        #expect(queue.isEmpty(for: serverA))
        #expect(queue.count(for: serverA) == 0)
        // serverB 不受影响
        #expect(queue.count(for: serverB) == 1)
    }

    @Test("count 返回指定服务器的排队任务数量")
    func count_returnsTaskCountForServer() {
        let queue = PerServerTaskQueue()
        let serverID = UUID()

        #expect(queue.count(for: serverID) == 0)

        queue.enqueue(QueuedTask(serverID: serverID, text: "one"))
        queue.enqueue(QueuedTask(serverID: serverID, text: "two"))

        #expect(queue.count(for: serverID) == 2)
    }
}
