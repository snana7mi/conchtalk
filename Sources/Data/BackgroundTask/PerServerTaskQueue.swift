/// 文件说明：PerServerTaskQueue，按服务器隔离的 FIFO 指令排队管理。
import Foundation

// MARK: - QueuedTask

/// QueuedTask：
/// 表示一条待执行的排队指令，包含目标服务器 ID、文本内容及附件。
nonisolated struct QueuedTask: Identifiable, Sendable {
    let id: UUID
    let serverID: UUID
    let text: String
    let attachments: [FileAttachment]
    let enqueuedAt: Date

    init(
        id: UUID = UUID(),
        serverID: UUID,
        text: String,
        attachments: [FileAttachment] = [],
        enqueuedAt: Date = Date()
    ) {
        self.id = id
        self.serverID = serverID
        self.text = text
        self.attachments = attachments
        self.enqueuedAt = enqueuedAt
    }
}

// MARK: - PerServerTaskQueue

/// PerServerTaskQueue：
/// 按服务器 ID 隔离的 FIFO 排队管理器。
/// 每个服务器维护独立的任务队列，互不干扰。
@MainActor @Observable
final class PerServerTaskQueue {
    /// 按服务器 ID 分组的排队任务。
    private var queues: [UUID: [QueuedTask]] = [:]

    /// 将任务加入对应服务器的队尾。
    func enqueue(_ task: QueuedTask) {
        queues[task.serverID, default: []].append(task)
    }

    /// 取出指定服务器的队首任务并从队列移除；队列为空时返回 nil。
    func dequeue(for serverID: UUID) -> QueuedTask? {
        guard var queue = queues[serverID], !queue.isEmpty else { return nil }
        let task = queue.removeFirst()
        if queue.isEmpty {
            queues.removeValue(forKey: serverID)
        } else {
            queues[serverID] = queue
        }
        return task
    }

    /// 取消指定服务器中指定 ID 的排队任务（若不存在则静默忽略）。
    func cancel(serverID: UUID, taskID: UUID) {
        queues[serverID]?.removeAll { $0.id == taskID }
        // 清理空队列
        if queues[serverID]?.isEmpty == true {
            queues.removeValue(forKey: serverID)
        }
    }

    /// 返回指定服务器的所有排队任务快照（按入队顺序）。
    func tasks(for serverID: UUID) -> [QueuedTask] {
        queues[serverID] ?? []
    }

    /// 取消指定服务器的所有排队任务。
    func cancelAll(for serverID: UUID) {
        queues.removeValue(forKey: serverID)
    }

    /// 指定服务器的排队任务数量。
    func count(for serverID: UUID) -> Int {
        queues[serverID]?.count ?? 0
    }

    /// 指定服务器的队列是否为空。
    func isEmpty(for serverID: UUID) -> Bool {
        queues[serverID]?.isEmpty ?? true
    }
}
