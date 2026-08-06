/// 文件说明：BackgroundDisconnectionPlanTests，验证后台断线计划的服务器分组逻辑。
import Testing
@testable import ConchTalk
import Foundation

@Suite("Background Disconnection Plan")
struct BackgroundDisconnectionPlanTests {
    @Test("当前聊天服务器断线时优先原地重连，仅清理其他服务器")
    func prioritizesCurrentChatServerForReconnect() {
        let currentServerID = UUID()
        let otherServerID = UUID()

        let plan = BackgroundDisconnectionPlan(
            disconnectedServerIDs: [otherServerID, currentServerID],
            currentChatServerID: currentServerID
        )

        #expect(plan.reconnectInPlaceServerID == currentServerID)
        #expect(plan.cleanupServerIDs == [otherServerID])
    }

    @Test("没有当前聊天服务器时全部走清理流程")
    func cleansUpAllServersWhenNoCurrentChatServer() {
        let server1 = UUID()
        let server2 = UUID()

        let plan = BackgroundDisconnectionPlan(
            disconnectedServerIDs: [server1, server2],
            currentChatServerID: nil
        )

        #expect(plan.reconnectInPlaceServerID == nil)
        #expect(plan.cleanupServerIDs == [server1, server2])
    }
}
