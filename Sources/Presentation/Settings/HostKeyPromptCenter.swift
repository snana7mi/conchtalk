/// 文件说明：HostKeyPromptCenter，把 SSH 握手里的指纹确认挂到界面上。
import SwiftUI

/// HostKeyPromptCenter：
/// 主线程上一次只展示一条确认。下一条排队，避免两台服务器同时连时互相覆盖。
@MainActor
@Observable
final class HostKeyPromptCenter: HostKeyPrompting {
    private(set) var pending: HostKeyPrompt?
    private var waiter: CheckedContinuation<HostKeyPromptDecision, Never>?
    private var queue: [(HostKeyPrompt, CheckedContinuation<HostKeyPromptDecision, Never>)] = []

    func decide(_ prompt: HostKeyPrompt) async -> HostKeyPromptDecision {
        await withCheckedContinuation { continuation in
            // The body runs synchronously on the caller's executor (this @MainActor method).
            MainActor.assumeIsolated {
                if waiter == nil {
                    pending = prompt
                    waiter = continuation
                } else {
                    queue.append((prompt, continuation))
                }
            }
        }
    }

    /// 用户在确认页做出选择。没有挂起的请求时忽略，避免关闭页面时二次 resume。
    func answer(_ decision: HostKeyPromptDecision) {
        guard let waiter else { return }
        self.waiter = nil
        pending = nil
        waiter.resume(returning: decision)
        promote()
    }

    /// 连接被取消时拒绝当前和排队中的全部确认，让握手能够结束。
    func rejectAll() {
        let current = waiter
        waiter = nil
        pending = nil
        current?.resume(returning: .reject)
        let queued = queue
        queue.removeAll()
        for item in queued {
            item.1.resume(returning: .reject)
        }
    }

    private func promote() {
        guard !queue.isEmpty else { return }
        let next = queue.removeFirst()
        pending = next.0
        waiter = next.1
    }
}
