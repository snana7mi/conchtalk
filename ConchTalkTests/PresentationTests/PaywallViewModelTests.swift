/// 文件说明：PaywallViewModelTests，验证 Paywall 的购买和恢复逻辑。
import Testing
@testable import ConchTalk

@Suite("PaywallViewModel")
struct PaywallViewModelTests {

    @Test("purchase 调用 subscriptionService.purchase")
    func purchaseCallsService() async {
        let mockService = MockSubscriptionService()
        let vm = PaywallViewModel(subscriptionService: mockService)

        await vm.purchase()
        #expect(mockService.purchaseCalled == true)
    }

    @Test("restore 调用 subscriptionService.restore")
    func restoreCallsService() async {
        let mockService = MockSubscriptionService()
        let vm = PaywallViewModel(subscriptionService: mockService)

        await vm.restore()
        #expect(mockService.restoreCalled == true)
    }

    @Test("purchaseState 反映 subscriptionService 的状态")
    func purchaseStateReflectsService() {
        let mockService = MockSubscriptionService()
        mockService.purchaseState = .success
        let vm = PaywallViewModel(subscriptionService: mockService)

        #expect(vm.purchaseState == .success)
    }
}
