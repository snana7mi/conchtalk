/// 文件说明：SubscriptionServiceProtocol，订阅服务抽象契约。

/// SubscriptionServiceProtocol：定义订阅服务的公开接口，便于 DI 和测试。
protocol SubscriptionServiceProtocol: AnyObject {
    /// 当前订阅产品的展示价格（如 "¥12.00 / 月"），nil 表示尚未加载。
    var displayPrice: String? { get }
    var purchaseState: PurchaseState { get }
    func startListening()
    func loadProducts() async
    func purchase() async
    func restore() async
}
