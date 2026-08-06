/// 文件说明：SubagentApprovalGate，把并行 subagent 的确认请求串行化为一次一个。
import Foundation

/// SubagentApprovalGate：
/// FIFO + 单许可闸门。现有审批是 per-serverID 单槽（同一时刻只能挂起一个 continuation），
/// 并行 subagent 若同时冒泡确认会互相覆盖导致挂起；本闸保证一次只放行一个确认冒泡。
actor SubagentApprovalGate {
    /// 许可是否已被占用。一旦有请求拿到许可即为 true，直到最后一个等待者释放才回到 false。
    private var busy = false
    /// FIFO 等待队列：拿不到许可的请求在此挂起，按入队顺序被逐个唤醒。
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// 串行地把一次确认请求冒泡到父回调。
    /// 在 `await parentCallback` 执行期间持续持有许可，确保父回调不会重叠执行（maxConcurrent == 1）。
    func requestConfirmation(
        _ request: ConfirmationRequest,
        via parentCallback: @Sendable (ConfirmationRequest) async -> CommandApproval
    ) async -> CommandApproval {
        await acquire()
        // 用 defer 保证无论正常返回还是被取消，许可都会被释放/移交，杜绝闸门死锁。
        defer { release() }
        return await parentCallback(request)
    }

    /// 获取许可：空闲则直接占用；否则把自己挂入 FIFO 队列等待被唤醒。
    private func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    /// 释放许可：若有等待者，则把许可「直接移交」给队首（busy 保持 true，不重置），
    /// 从而维持「同一时刻只有一个请求处于临界区」的不变式；无等待者时才真正置空。
    private func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}
