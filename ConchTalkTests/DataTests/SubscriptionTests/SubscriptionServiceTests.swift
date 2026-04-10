/// 文件说明：SubscriptionServiceTests，验证 SubscriptionService 的常量和配置。
import Testing
@testable import ConchTalk

@Suite("SubscriptionService")
struct SubscriptionServiceTests {

    @Test("entitlementID 为 conchtalk Pro")
    func entitlementID() {
        #expect(SubscriptionService.entitlementID == "conchtalk Pro")
    }
}
