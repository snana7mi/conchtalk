/// 文件说明：MockSubscriptionService，用于 Paywall 等 UI 测试的 mock。
import Foundation
@testable import ConchTalk

@Observable
final class MockSubscriptionService: SubscriptionServiceProtocol, @unchecked Sendable {
    var displayPrice: String?
    var purchaseState: PurchaseState = .idle

    var purchaseCalled = false
    var restoreCalled = false

    func startListening() {}

    func loadProducts() async {}

    func purchase() async {
        purchaseCalled = true
    }

    func restore() async {
        restoreCalled = true
    }
}
