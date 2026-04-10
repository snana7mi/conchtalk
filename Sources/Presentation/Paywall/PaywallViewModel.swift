/// 文件说明：PaywallViewModel，驱动 Paywall 页面的购买和恢复逻辑。
import Foundation

/// PaywallViewModel：封装 SubscriptionService 的购买/恢复操作，供 PaywallView 使用。
@Observable
final class PaywallViewModel {
    private let subscriptionService: SubscriptionServiceProtocol

    init(subscriptionService: SubscriptionServiceProtocol) {
        self.subscriptionService = subscriptionService
    }

    /// 当前购买状态（直接代理 subscriptionService）。
    var purchaseState: PurchaseState {
        subscriptionService.purchaseState
    }

    /// 订阅产品的展示价格。
    var displayPrice: String? {
        subscriptionService.displayPrice
    }

    /// 加载商品信息。
    func loadProducts() async {
        await subscriptionService.loadProducts()
    }

    /// 发起购买。
    func purchase() async {
        await subscriptionService.purchase()
    }

    /// 恢复购买。
    func restore() async {
        await subscriptionService.restore()
    }
}
