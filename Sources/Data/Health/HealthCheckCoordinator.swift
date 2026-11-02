/// 文件说明：HealthCheckCoordinator，按 iOS 后台刷新的限制调度磁盘、负载和服务检查。
import Foundation

/// HealthCheckCoordinator：
/// 每次系统唤醒最多检查一台到期的服务器，然后重新提交下一次请求。
/// 探测命令是固定的只读脚本，不经过 AI，也不提升权限。
@MainActor
final class HealthCheckCoordinator {
    private let store: FileHealthCheckStore
    private let scheduler: any HealthRefreshScheduling
    private let bundleIdentifier: String
    private let serverLookup: @MainActor (UUID) async -> Server?
    private let probe: @MainActor (Server, HealthThresholds) async -> Result<HealthProbeReading, Error>
    private let notify: @MainActor (Server, [HealthBreach]) -> Void
    private var isRunning = false

    init(
        store: FileHealthCheckStore,
        scheduler: any HealthRefreshScheduling,
        bundleIdentifier: String,
        serverLookup: @escaping @MainActor (UUID) async -> Server?,
        probe: @escaping @MainActor (Server, HealthThresholds) async -> Result<HealthProbeReading, Error>,
        notify: @escaping @MainActor (Server, [HealthBreach]) -> Void
    ) {
        self.store = store
        self.scheduler = scheduler
        self.bundleIdentifier = bundleIdentifier
        self.serverLookup = serverLookup
        self.probe = probe
        self.notify = notify
    }

    var taskIdentifier: String {
        HealthCheckBridge.identifier(bundleIdentifier: bundleIdentifier)
    }

    func plans() -> [HealthCheckPlan] {
        (try? store.loadAll()) ?? []
    }

    func replace(_ plans: [HealthCheckPlan]) {
        try? store.save(plans)
        reschedule()
    }

    /// 容器就绪后接上系统唤醒，并提交下一次刷新。
    func start() {
        HealthCheckBridge.shared.handler = { [weak self] task in
            guard let self else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { await self.handle(task) }
        }
        HealthCheckBridge.shared.flushPending()
        reschedule()
    }

    func reschedule(now: Date = Date()) {
        let identifier = taskIdentifier
        scheduler.cancel(identifier: identifier)
        let plans = plans()
        guard plans.contains(where: \.enabled) else { return }
        let begin = HealthCheckSchedule.earliestBegin(plans: plans, now: now)
        try? scheduler.submit(identifier: identifier, earliestBegin: begin)
    }

    /// 用户在前台打开检查时立刻跑一台，不等后台唤醒。
    func runNow(planID: UUID, now: Date = Date()) async {
        await run(planID: planID, now: now)
        reschedule(now: now)
    }

    func handle(_ task: any HealthRefreshTask) async {
        final class Flag: @unchecked Sendable {
            var value = false
        }
        let expired = Flag()
        task.setExpirationHandler { expired.value = true }
        if !expired.value {
            _ = await runNextDue()
        }
        task.setTaskCompleted(success: !expired.value)
        reschedule()
    }

    /// 测试和唤醒共用：只跑最早到期的一台。返回实际检查的服务器。
    @discardableResult
    func runNextDue(now: Date = Date()) async -> UUID? {
        guard let plan = HealthCheckSchedule.nextDue(plans: plans(), now: now) else { return nil }
        await run(planID: plan.id, now: now)
        return plan.serverID
    }

    private func run(planID: UUID, now: Date) async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }

        var plans = plans()
        guard let index = plans.firstIndex(where: { $0.id == planID }) else { return }
        let plan = plans[index]
        guard let server = await serverLookup(plan.serverID) else {
            plans[index].lastRunAt = now
            plans[index].lastSummary = String(localized: "Server not found", bundle: LanguageSettings.currentBundle)
            try? store.save(plans)
            return
        }

        if HealthProbeCommand.script(services: plan.thresholds.sanitized().services) == nil {
            let breach = HealthBreach.unreachable(String(localized: "A service name is not safe to check.", bundle: LanguageSettings.currentBundle))
            plans[index].lastRunAt = now
            plans[index].lastSummary = HealthAlertMessage.body(breaches: [breach])
            try? store.save(plans)
            notify(server, [breach])
            return
        }

        let result = await probe(server, plan.thresholds.sanitized())
        switch result {
        case .failure(let error):
            let breach = HealthBreach.unreachable(error.localizedDescription)
            plans[index].lastRunAt = now
            plans[index].lastSummary = error.localizedDescription
            try? store.save(plans)
            notify(server, [breach])
        case .success(let reading):
            let verdict = HealthCheckEvaluator.evaluate(reading: reading, thresholds: plan.thresholds)
            switch verdict {
            case .healthy:
                plans[index].lastSummary = String(localized: "Healthy", bundle: LanguageSettings.currentBundle)
            case .breached(let breaches):
                plans[index].lastSummary = HealthAlertMessage.body(breaches: breaches)
                notify(server, breaches)
            }
            plans[index].lastRunAt = now
            try? store.save(plans)
        }
    }
}

/// HealthAlertMessage：把越限结果收成一条本地通知正文。
enum HealthAlertMessage {
    static func body(breaches: [HealthBreach]) -> String {
        let bundle = LanguageSettings.currentBundle
        let locale = LanguageSettings.currentLocale
        return breaches.prefix(3).map { breach in
            switch breach {
            case .disk(let mount, let used, let limit):
                return String(
                    format: String(localized: "Disk %@ is %d%% (limit %d%%).", bundle: bundle),
                    locale: locale,
                    mount,
                    used,
                    limit
                )
            case .load(let value, let limit):
                return String(
                    format: String(localized: "Load average %.2f is at or above %.2f.", bundle: bundle),
                    locale: locale,
                    value,
                    limit
                )
            case .service(let name, let state):
                return String(
                    format: String(localized: "Service %@ is %@.", bundle: bundle),
                    locale: locale,
                    name,
                    state
                )
            case .unreachable(let message):
                return message
            }
        }.joined(separator: " ")
    }
}
