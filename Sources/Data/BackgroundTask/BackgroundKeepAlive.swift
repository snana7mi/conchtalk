/// 文件说明：BackgroundKeepAlive，iOS 后台保活管理。
import Foundation
import UIKit

/// BackgroundKeepAlive：
/// 管理 iOS 后台任务保活。在有活跃 AI 任务时申请短时保活（约 30 秒），
/// 让当前轮 AI 结果有机会写入并通知用户。
@MainActor
final class BackgroundKeepAlive {
    private var bgKeepAliveTaskID: UIBackgroundTaskIdentifier = .invalid

    /// 进入后台时申请短时保活。
    func beginBackgroundKeepAlive() {
        guard bgKeepAliveTaskID == .invalid else { return }
        bgKeepAliveTaskID = UIApplication.shared.beginBackgroundTask(withName: "AIRoundCompletion") { [weak self] in
            // iOS 即将终止后台时间，主动结束以避免被强杀
            Task { @MainActor in
                self?.endBackgroundKeepAlive()
            }
        }
        print("[BTM] beginBackgroundKeepAlive: \(bgKeepAliveTaskID.rawValue)")
    }

    /// 结束短时保活任务（幂等）。
    func endBackgroundKeepAlive() {
        guard bgKeepAliveTaskID != .invalid else { return }
        let taskID = bgKeepAliveTaskID
        bgKeepAliveTaskID = .invalid
        UIApplication.shared.endBackgroundTask(taskID)
        print("[BTM] endBackgroundKeepAlive: \(taskID.rawValue)")
    }
}
