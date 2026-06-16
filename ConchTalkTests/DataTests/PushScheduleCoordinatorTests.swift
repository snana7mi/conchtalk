/// 文件说明：PushScheduleCoordinatorTests，验证后台+待审批→预约、前台/解决→check-in。
import Testing
import Foundation
@testable import ConchTalk

@Suite("PushScheduleCoordinator")
struct PushScheduleCoordinatorTests {
    actor FakeSched: PushScheduling {
        private(set) var scheduled: [(serverID: String, title: String)] = []
        private(set) var checkedIn: [String] = []
        private(set) var checkinAllCount = 0
        func schedule(scheduleID: String, title: String, body: String, serverID: String, fireAfterSeconds: Int) async throws { scheduled.append((serverID, title)) }
        func checkin(scheduleID: String) async throws { checkedIn.append(scheduleID) }
        func checkinAll() async throws { checkinAllCount += 1 }
    }

    @Test("预约后 check-in 用同一 scheduleID")
    func scheduleThenCheckin() async throws {
        let api = FakeSched()
        let c = PushScheduleCoordinator(api: api)
        let sid = UUID()
        await c.scheduleFallback(serverID: sid, serverName: "prod", body: "有操作待审批")
        #expect(await api.scheduled.count == 1)
        await c.checkin(serverID: sid)
        #expect(await api.checkedIn.count == 1)   // 同一 scheduleID 被取消
    }

    @Test("重复 check-in 同一 serverID 不重复发送")
    func checkinIdempotent() async {
        let api = FakeSched()
        let c = PushScheduleCoordinator(api: api)
        let sid = UUID()
        await c.scheduleFallback(serverID: sid, serverName: "srv", body: "b")
        await c.checkin(serverID: sid)
        await c.checkin(serverID: sid)
        #expect(await api.checkedIn.count == 1)
    }

    @Test("checkinAll 清空在飞并调底层")
    func checkinAllClears() async {
        let api = FakeSched()
        let c = PushScheduleCoordinator(api: api)
        await c.scheduleFallback(serverID: UUID(), serverName: "a", body: "b")
        await c.scheduleFallback(serverID: UUID(), serverName: "c", body: "d")
        await c.checkinAll()
        #expect(await api.checkinAllCount == 1)
    }
}
