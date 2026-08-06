/// 文件说明：AsyncMutex，异步互斥锁，必须在单一隔离域（actor 或 @MainActor）内使用。
import Foundation

/// AsyncMutex：
/// 异步互斥锁。非 actor 类型 — 必须在单一隔离域（actor 或 @MainActor）内使用。
/// `defer { mutex.unlock() }` 安全（无 await）。
///
/// 隔离域要求：
/// - 在 `ShellChannel`（actor）中使用时，actor 本身保证串行访问。
/// - 在 `SSHSessionManager`（`@MainActor` class）中使用时，MainActor 保证串行访问。
/// - **禁止**在无隔离保证的普通 class/struct 中使用。
final class AsyncMutex: @unchecked Sendable {
    nonisolated(unsafe) private var isLocked = false
    nonisolated(unsafe) private var isPoisoned = false
    nonisolated(unsafe) private var waiters: [CheckedContinuation<Void, Error>] = []

    nonisolated init() {}

    /// 获取锁。返回时表示成功持有锁。
    /// poisoned 时抛 `SSHError.notConnected`。
    /// 取消安全：被取消的 waiter 被 `unlock()` 唤醒后会立即转交锁并抛 `CancellationError`。
    nonisolated func lock() async throws {
        if isPoisoned { throw SSHError.notConnected }
        if !isLocked {
            isLocked = true
            return
        }
        // 挂起等待：采用协作式取消，被唤醒后检查取消状态。
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            waiters.append(cont)
            if waiters.count > 5 {
                print("[AsyncMutex] ⚠️ \(waiters.count) waiters queued — possible slow lock holder")
            }
        }
        // 到这里锁已被 unlock() 交接给我们（isLocked 仍为 true）。
        // 如果 Task 在等待期间被取消，立即转交锁并抛出取消。
        if Task.isCancelled {
            unlock()  // 转交给下一个 waiter 或释放
            throw CancellationError()
        }
    }

    /// 释放锁。poisoned 后调用为 no-op（宽容语义，不触发断言）。
    nonisolated func unlock() {
        guard !isPoisoned else { return }  // poison 后宽容 no-op
        guard isLocked else {
            assertionFailure("[AsyncMutex] unlock called without holding lock")
            return
        }
        if let next = waiters.first {
            waiters.removeFirst()
            // 锁状态不变（isLocked 仍为 true），交接给下一个 waiter。
            // 若该 waiter 已被取消，其 lock() 会再次 unlock() 形成链式转交。
            next.resume(returning: ())
        } else {
            isLocked = false
        }
    }

    /// 毒化：标记不可用，fail 所有等待者，释放锁。
    nonisolated func poison() {
        isPoisoned = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume(throwing: SSHError.notConnected)
        }
        isLocked = false
    }
}
