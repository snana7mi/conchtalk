/// 文件说明：HealthProbe，解析只读健康检查输出并和阈值比较。
import Foundation

/// DiskSample：一个挂载点的使用百分比。
nonisolated struct DiskSample: Equatable, Sendable {
    var mount: String
    var usedPercent: Int
}

/// ServiceSample：一个 systemd 单元的 `is-active` 结果。
nonisolated struct ServiceSample: Equatable, Sendable {
    var name: String
    var state: String
}

/// HealthProbeReading：一次探测读到的磁盘、1 分钟负载和服务状态。
nonisolated struct HealthProbeReading: Equatable, Sendable {
    var disks: [DiskSample]
    var loadAverage: Double?
    var services: [ServiceSample]
}

/// HealthBreach：越过阈值或服务不在 active。
nonisolated enum HealthBreach: Equatable, Sendable {
    case disk(mount: String, usedPercent: Int, limit: Int)
    case load(value: Double, limit: Double)
    case service(name: String, state: String)
    case unreachable(String)
}

/// HealthVerdict：一台服务器这次检查的结论。
nonisolated enum HealthVerdict: Equatable, Sendable {
    case healthy
    case breached([HealthBreach])
}

/// HealthProbeCommand：固定的只读探测脚本。服务名不合法时拒绝生成命令。
nonisolated enum HealthProbeCommand {
    static func isSafeServiceName(_ name: String) -> Bool {
        guard (1...128).contains(name.count) else { return false }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789:_@.-")
        return name.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// 生成远端只读脚本。任一服务名不安全时返回 nil，调用方不得执行。
    static func script(services: [String]) -> String? {
        for name in services where !isSafeServiceName(name) {
            return nil
        }
        let checks = services.map { name in
            "printf '%s %s\\n' '\(name)' \"$(systemctl is-active '\(name)' 2>/dev/null || echo unknown)\""
        }.joined(separator: "\n")
        return """
        df -P
        printf '\\n---LOAD---\\n'
        cat /proc/loadavg
        printf '\\n---SERVICES---\\n'
        \(checks)
        """
    }
}

/// HealthProbeParser：把 `df -P`、`/proc/loadavg` 和 systemctl 输出拆开。
nonisolated enum HealthProbeParser {
    private static let skipFilesystems = ["tmpfs", "devtmpfs", "udev", "overlay"]

    static func parse(_ output: String, expectedServices: [String]) -> HealthProbeReading {
        let sections = output.components(separatedBy: "---LOAD---")
        let diskText = sections.first ?? ""
        let rest = sections.count > 1 ? sections[1] : ""
        let serviceParts = rest.components(separatedBy: "---SERVICES---")
        let loadText = serviceParts.first ?? ""
        let serviceText = serviceParts.count > 1 ? serviceParts[1] : ""
        return HealthProbeReading(
            disks: parseDisk(diskText),
            loadAverage: parseLoad(loadText),
            services: parseServices(serviceText, expected: expectedServices)
        )
    }

    static func parseDisk(_ output: String) -> [DiskSample] {
        var samples: [DiskSample] = []
        for (index, raw) in output.split(whereSeparator: \.isNewline).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if index == 0 && line.hasPrefix("Filesystem") { continue }
            let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard let percentIndex = parts.firstIndex(where: { $0.hasSuffix("%") }),
                  percentIndex + 1 < parts.count else { continue }
            let filesystem = parts[0]
            if skipFilesystems.contains(where: { filesystem.contains($0) }) { continue }
            let percent = Int(parts[percentIndex].dropLast()) ?? 0
            let mount = parts[(percentIndex + 1)...].joined(separator: " ")
            samples.append(DiskSample(mount: mount, usedPercent: percent))
        }
        return samples
    }

    static func parseLoad(_ output: String) -> Double? {
        let token = output.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        return Double(token)
    }

    static func parseServices(_ output: String, expected: [String]) -> [ServiceSample] {
        var found: [String: String] = [:]
        for raw in output.split(whereSeparator: \.isNewline) {
            let parts = raw.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard parts.count >= 2 else { continue }
            found[parts[0]] = parts[1]
        }
        return expected.map { name in
            ServiceSample(name: name, state: found[name] ?? "unknown")
        }
    }
}

/// HealthCheckEvaluator：阈值比较。使用百分比和负载都是大于等于阈值才告警。
nonisolated enum HealthCheckEvaluator {
    static func evaluate(reading: HealthProbeReading, thresholds: HealthThresholds) -> HealthVerdict {
        let limits = thresholds.sanitized()
        var breaches: [HealthBreach] = []
        for disk in reading.disks where disk.usedPercent >= limits.diskUsedPercent {
            breaches.append(.disk(mount: disk.mount, usedPercent: disk.usedPercent, limit: limits.diskUsedPercent))
        }
        if let load = reading.loadAverage, load >= limits.loadAverage {
            breaches.append(.load(value: load, limit: limits.loadAverage))
        }
        for service in reading.services where service.state != "active" {
            breaches.append(.service(name: service.name, state: service.state))
        }
        if breaches.isEmpty { return .healthy }
        return .breached(breaches)
    }
}

/// HealthCheckSchedule：决定这次唤醒检查哪一台，以及下一次最早可以请求的时间。
nonisolated enum HealthCheckSchedule {
    /// 一次唤醒只返回一台到期的服务器，避免超出后台刷新的短执行窗口。
    static func nextDue(plans: [HealthCheckPlan], now: Date) -> HealthCheckPlan? {
        let due = plans.filter { plan in
            guard plan.enabled else { return false }
            guard let last = plan.lastRunAt else { return true }
            return now.timeIntervalSince(last) >= HealthCheckLimits.clampedInterval(plan.requestedInterval)
        }
        return due.min { lhs, rhs in
            (lhs.lastRunAt ?? .distantPast) < (rhs.lastRunAt ?? .distantPast)
        }
    }

    /// 下一次 `earliestBeginDate`。不会早于现在 + 15 分钟。
    static func earliestBegin(plans: [HealthCheckPlan], now: Date) -> Date {
        let floor = now.addingTimeInterval(HealthCheckLimits.minimumInterval)
        let enabled = plans.filter(\.enabled)
        guard !enabled.isEmpty else { return floor }
        let soonest = enabled.map { plan -> Date in
            let interval = HealthCheckLimits.clampedInterval(plan.requestedInterval)
            guard let last = plan.lastRunAt else { return floor }
            return last.addingTimeInterval(interval)
        }.min() ?? floor
        return max(soonest, floor)
    }
}
