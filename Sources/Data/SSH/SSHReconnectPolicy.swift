/// 文件说明：SSHReconnectPolicy，SSH 重连的指数退避策略。
import Foundation

/// SSHReconnectPolicy：
/// 定义 SSH 断连后自动重试的次数与延迟间隔。
/// 延迟按指数递增（2s → 4s → 8s → 16s），上限 16 秒。
struct SSHReconnectPolicy: Sendable {
    /// 最大重试次数。
    let maxAttempts = 4
    /// 基础延迟（秒）。
    let baseDelay: TimeInterval = 2
    /// 最大延迟（秒）。
    let maxDelay: TimeInterval = 16

    /// 计算第 N 次重试的延迟。
    func delay(forAttempt attempt: Int) -> TimeInterval {
        min(baseDelay * pow(2, Double(attempt)), maxDelay)
    }
}
