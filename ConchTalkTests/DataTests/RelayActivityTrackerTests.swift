/// 文件说明：RelayActivityTrackerTests，验证 relay 灵动岛 5 分钟倒计时逻辑。
import Testing
import Foundation

@testable import ConchTalk

@MainActor
struct RelayActivityTrackerTests {
    @Test func serverDidEnter_addsToActiveServers() {
        let tracker = RelayActivityTracker(expiryInterval: 5)
        let id = UUID()
        tracker.serverDidEnter(id)
        #expect(tracker.hasActiveServers)
        #expect(tracker.activeServerIDs.contains(id))
    }

    @Test func serverDidLeave_startsExpiry() async throws {
        let tracker = RelayActivityTracker(expiryInterval: 0.1)
        let id = UUID()
        tracker.serverDidEnter(id)
        tracker.serverDidLeave(id)
        #expect(tracker.hasActiveServers)
        try await Task.sleep(for: .milliseconds(200))
        #expect(!tracker.hasActiveServers)
        #expect(!tracker.activeServerIDs.contains(id))
    }

    @Test func reenter_resetsExpiry() async throws {
        let tracker = RelayActivityTracker(expiryInterval: 0.1)
        let id = UUID()
        tracker.serverDidEnter(id)
        tracker.serverDidLeave(id)
        try await Task.sleep(for: .milliseconds(50))
        tracker.serverDidEnter(id)
        try await Task.sleep(for: .milliseconds(100))
        #expect(tracker.hasActiveServers)
    }

    @Test func multipleServers_independentTimers() async throws {
        let tracker = RelayActivityTracker(expiryInterval: 0.1)
        let id1 = UUID()
        let id2 = UUID()
        tracker.serverDidEnter(id1)
        tracker.serverDidEnter(id2)
        tracker.serverDidLeave(id1)
        try await Task.sleep(for: .milliseconds(200))
        #expect(!tracker.activeServerIDs.contains(id1))
        #expect(tracker.activeServerIDs.contains(id2))
    }

    @Test func removeAll_clearsEverything() {
        let tracker = RelayActivityTracker(expiryInterval: 300)
        tracker.serverDidEnter(UUID())
        tracker.serverDidEnter(UUID())
        tracker.removeAll()
        #expect(!tracker.hasActiveServers)
    }
}
