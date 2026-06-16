/// 文件说明：NotificationServiceActionTests，验证本地通知的 Approve/Deny 动作与远程深链解析。
import Testing
import Foundation
@testable import ConchTalk

@Suite("NotificationServiceAction")
struct NotificationServiceActionTests {
    @Test("approve 动作在有待审批时回调 resolve(.approvedOnce)")
    func approveAction() async {
        let svc = NotificationService()
        let sid = UUID()
        var resolved: (UUID, CommandApproval)?
        svc.onNotificationApproval = { serverID, outcome in resolved = (serverID, outcome) }
        await svc.handleAction(actionIdentifier: "APPROVE_ONCE",
                               userInfo: ["serverID": sid.uuidString], hasPendingApproval: { _ in true })
        #expect(resolved?.0 == sid)
        #expect(resolved?.1 == .approvedOnce)
    }

    @Test("远程推送点开(默认动作)解析为导航")
    func remoteTapNavigates() {
        let nav = NotificationService.parseNavigation(from: ["serverID": UUID().uuidString])
        #expect(nav != nil)
    }
}
