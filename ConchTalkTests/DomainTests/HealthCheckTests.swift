/// 文件说明：HealthCheckTests，覆盖健康检查解析、阈值、调度间隔和一次唤醒只查一台。
import Testing
@testable import ConchTalk
import Foundation

@Suite("Health checks")
struct HealthCheckTests {
    private let sample = """
    Filesystem     1024-blocks      Used Available Capacity Mounted on
    /dev/root        20971520  18874368   2097152      91% /
    tmpfs              102400     20480     81920      20% /run
    /dev/sda1         1024000    512000    512000      50% /boot
    ---LOAD---
    4.20 3.10 2.50 2/180 1001
    ---SERVICES---
    nginx active
    ssh inactive
    """

    @Test("解析 df、负载和服务，并忽略 tmpfs")
    func parsesProbeOutput() {
        let reading = HealthProbeParser.parse(sample, expectedServices: ["nginx", "ssh", "missing"])
        #expect(reading.disks.map(\.mount) == ["/", "/boot"])
        #expect(reading.disks[0].usedPercent == 91)
        #expect(abs((reading.loadAverage ?? 0) - 4.2) < 0.001)
        #expect(reading.services == [
            ServiceSample(name: "nginx", state: "active"),
            ServiceSample(name: "ssh", state: "inactive"),
            ServiceSample(name: "missing", state: "unknown"),
        ])
    }

    @Test("磁盘、负载和不活跃服务会越限，active 服务不会")
    func evaluatesThresholds() {
        let reading = HealthProbeParser.parse(sample, expectedServices: ["nginx", "ssh"])
        let verdict = HealthCheckEvaluator.evaluate(
            reading: reading,
            thresholds: HealthThresholds(diskUsedPercent: 90, loadAverage: 4, services: ["nginx", "ssh"])
        )
        guard case .breached(let breaches) = verdict else {
            Issue.record("expected breaches")
            return
        }
        #expect(breaches.contains(.disk(mount: "/", usedPercent: 91, limit: 90)))
        #expect(!breaches.contains(.disk(mount: "/boot", usedPercent: 50, limit: 90)))
        #expect(breaches.contains { breach in
            if case .load(let value, let limit) = breach { return value >= 4 && limit == 4 }
            return false
        })
        #expect(breaches.contains(.service(name: "ssh", state: "inactive")))
        #expect(!breaches.contains { if case .service(let name, _) = $0 { return name == "nginx" } else { return false } })
    }

    @Test("不安全的服务名不会生成命令")
    func rejectsUnsafeServiceNames() {
        #expect(HealthProbeCommand.isSafeServiceName("nginx"))
        #expect(HealthProbeCommand.isSafeServiceName("user@host.service"))
        #expect(!HealthProbeCommand.isSafeServiceName("nginx;reboot"))
        #expect(!HealthProbeCommand.isSafeServiceName("nginx rm"))
        #expect(HealthProbeCommand.script(services: ["nginx"])?.contains("systemctl is-active 'nginx'") == true)
        #expect(HealthProbeCommand.script(services: ["nginx;reboot"]) == nil)
    }

    @Test("请求间隔短于 15 分钟时抬到下限，下一次唤醒也不早于 15 分钟")
    func clampsSchedule() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(HealthCheckLimits.clampedInterval(60) == 15 * 60)
        let recent = HealthCheckPlan(
            serverID: UUID(),
            requestedInterval: 60,
            lastRunAt: now.addingTimeInterval(-60)
        )
        let begin = HealthCheckSchedule.earliestBegin(plans: [recent], now: now)
        #expect(begin.timeIntervalSince(now) >= 15 * 60)
    }

    @Test("一次唤醒只检查最早到期的一台，健康时不通知")
    @MainActor
    func oneServerPerWake() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = FileHealthCheckStore(directory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let older = TestFixtures.makeServer(name: "Older")
        let newer = TestFixtures.makeServer(name: "Newer")
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let plans = [
            HealthCheckPlan(serverID: newer.id, lastRunAt: now.addingTimeInterval(-30 * 60)),
            HealthCheckPlan(serverID: older.id, lastRunAt: now.addingTimeInterval(-2 * 60 * 60)),
        ]
        try? store.save(plans)
        let scheduler = FakeHealthScheduler()
        let probed = ProbeLog()
        let notes = NoteLog()
        let coordinator = HealthCheckCoordinator(
            store: store,
            scheduler: scheduler,
            bundleIdentifier: "com.cheung.ConchTalk",
            serverLookup: { id in
                [older, newer].first { $0.id == id }
            },
            probe: { server, _ in
                await probed.add(server.id)
                return .success(HealthProbeReading(disks: [DiskSample(mount: "/", usedPercent: 10)], loadAverage: 0.1, services: []))
            },
            notify: { _, breaches in
                Task { await notes.add(breaches.count) }
            }
        )

        let first = await coordinator.runNextDue(now: now)
        #expect(first == older.id)
        #expect(await probed.ids == [older.id])
        #expect(await notes.count == 0)

        let second = await coordinator.runNextDue(now: now)
        #expect(second == newer.id)
        coordinator.reschedule(now: now)
        #expect((scheduler.submitted.last?.timeIntervalSince(now) ?? 0) >= 15 * 60)
    }

    @Test("Info.plist 声明了健康检查标识符和后台刷新")
    func infoPlistDeclaresHealthCheck() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Info.plist")
        let plist = try #require(NSDictionary(contentsOf: url))
        let ids = try #require(plist["BGTaskSchedulerPermittedIdentifiers"] as? [String])
        #expect(ids.contains("$(PRODUCT_BUNDLE_IDENTIFIER).healthCheck"))
        let modes = try #require(plist["UIBackgroundModes"] as? [String])
        #expect(modes.contains("fetch"))
    }
}

@MainActor
private final class FakeHealthScheduler: HealthRefreshScheduling {
    var submitted: [Date] = []

    func register(identifier: String, launchHandler: @escaping @MainActor (any HealthRefreshTask) -> Void) -> Bool {
        true
    }

    func submit(identifier: String, earliestBegin: Date) throws {
        submitted.append(earliestBegin)
    }

    func cancel(identifier: String) {}
}

private actor ProbeLog {
    private(set) var ids: [UUID] = []
    func add(_ id: UUID) { ids.append(id) }
}

private actor NoteLog {
    private(set) var count = 0
    func add(_ value: Int) { count += value }
}
