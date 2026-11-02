/// 文件说明：HealthCheckPlan，一台服务器的定时健康检查配置与最近一次结果。
import Foundation

/// HealthThresholds：磁盘、负载和服务的告警线。服务列表为空表示不检查服务。
nonisolated struct HealthThresholds: Codable, Equatable, Sendable {
    var diskUsedPercent: Int
    var loadAverage: Double
    var services: [String]

    static let `default` = HealthThresholds(diskUsedPercent: 90, loadAverage: 4, services: [])

    func sanitized() -> HealthThresholds {
        HealthThresholds(
            diskUsedPercent: min(99, max(1, diskUsedPercent)),
            loadAverage: min(256, max(0.1, loadAverage)),
            services: services
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
    }
}

/// HealthCheckPlan：本地保存的检查计划。间隔只是希望值，真正的唤醒由系统决定。
nonisolated struct HealthCheckPlan: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var serverID: UUID
    var enabled: Bool
    var thresholds: HealthThresholds
    /// 用户选择的间隔（秒）。提交给系统前会抬到 iOS 允许的最短间隔。
    var requestedInterval: TimeInterval
    var lastRunAt: Date?
    var lastSummary: String?

    init(
        id: UUID = UUID(),
        serverID: UUID,
        enabled: Bool = true,
        thresholds: HealthThresholds = .default,
        requestedInterval: TimeInterval = HealthCheckLimits.minimumInterval,
        lastRunAt: Date? = nil,
        lastSummary: String? = nil
    ) {
        self.id = id
        self.serverID = serverID
        self.enabled = enabled
        self.thresholds = thresholds
        self.requestedInterval = requestedInterval
        self.lastRunAt = lastRunAt
        self.lastSummary = lastSummary
    }
}

/// HealthCheckLimits：iOS 后台刷新做不到精确定时，这里记下代码必须遵守的下限。
nonisolated enum HealthCheckLimits {
    /// BGAppRefreshTask 的 earliestBeginDate 低于大约 15 分钟时，系统不会按更短的间隔唤醒。
    static let minimumInterval: TimeInterval = 15 * 60

    static func clampedInterval(_ requested: TimeInterval) -> TimeInterval {
        max(requested, minimumInterval)
    }
}
