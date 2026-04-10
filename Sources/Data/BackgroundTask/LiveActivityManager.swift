/// 文件说明：LiveActivityManager，管理全局单实例 Live Activity 生命周期与状态更新。
import Foundation
#if os(iOS)
import ActivityKit
#endif

/// LiveActivityManager：
/// 管理一个全局 Live Activity 实例，聚合展示所有已连接服务器的状态。
/// 内置节流机制（3 秒间隔），防止过于频繁的更新。
@MainActor
@Observable
final class LiveActivityManager {
    #if os(iOS)
    private var globalActivity: Activity<ConchTalkActivityAttributes>?
    #endif

    private var lastUpdateTime: Date?
    private let throttleInterval: TimeInterval = 3.0

    var isAvailable: Bool {
        #if os(iOS)
        ActivityAuthorizationInfo().areActivitiesEnabled
        #else
        false
        #endif
    }

    var isActive: Bool {
        #if os(iOS)
        globalActivity != nil
        #else
        false
        #endif
    }

    @discardableResult
    func startGlobalActivity() -> Bool {
        #if os(iOS)
        guard isAvailable else {
            print("[LiveActivity] 不可用（用户已禁用或系统不支持）")
            return false
        }
        if globalActivity != nil { return true }

        let attributes = ConchTalkActivityAttributes()
        let initialState = ConchTalkActivityAttributes.ContentState(servers: [])

        do {
            let activity = try Activity.request(
                attributes: attributes,
                content: .init(state: initialState, staleDate: nil),
                pushType: nil
            )
            globalActivity = activity
            lastUpdateTime = Date()
            print("[LiveActivity] 全局 Live Activity 已启动: id=\(activity.id)")
            return true
        } catch {
            print("[LiveActivity] 启动失败: \(error)")
            return false
        }
        #else
        return false
        #endif
    }

    func updateServers(_ snapshots: [ServerSnapshot], force: Bool = false) {
        #if os(iOS)
        guard let activity = globalActivity else { return }

        if !force, let lastTime = lastUpdateTime {
            let elapsed = Date().timeIntervalSince(lastTime)
            if elapsed < throttleInterval { return }
        }

        let state = ConchTalkActivityAttributes.ContentState(servers: snapshots)
        Task {
            await activity.update(.init(state: state, staleDate: nil))
        }
        lastUpdateTime = Date()
        #endif
    }

    func endGlobalActivity() {
        #if os(iOS)
        guard let activity = globalActivity else { return }

        let finalState = ConchTalkActivityAttributes.ContentState(servers: [])
        Task {
            await activity.end(.init(state: finalState, staleDate: nil), dismissalPolicy: .after(.now + 3))
        }
        globalActivity = nil
        lastUpdateTime = nil
        print("[LiveActivity] 全局 Live Activity 已结束")
        #endif
    }
}
