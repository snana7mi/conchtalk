/// 文件说明：SubscriptionService，ConchTalk 兼容层，委托 LLMGatewayKit 处理 RevenueCat 订阅流程。
import Foundation
import LLMGatewayKit

private typealias GatewaySubscriptionService = LLMGatewayKit.SubscriptionService

@Observable
final class SubscriptionService: SubscriptionServiceProtocol {
    /// 计算属性直接转发 gateway：购买全程的中间态（purchasing / verifying）实时驱动
    /// Paywall 的进度展示与防重复点击。@Observable 依赖追踪登记在最终被读取的
    /// gateway 存储属性上，gateway（@MainActor @Observable）每次赋值都会触发 View 重渲染。
    var displayPrice: String? { gateway.displayPrice }
    var purchaseState: PurchaseState { gateway.purchaseState.asConchTalkPurchaseState }

    static let entitlementID = "conchtalk Pro"

    private let gateway: GatewaySubscriptionService

    /// - Parameter purchaseClient: 测试缝隙；nil 时 gateway 按 config 自建 LivePurchaseClient，生产行为不变。
    init(authService: AuthServiceProtocol, purchaseClient: (any PurchaseClient)? = nil) {
        let concreteAuth = authService as? AuthService
        let config = LLMGatewayKitConfig(
            baseURL: URL(string: "https://api.conch-talk.com")!,
            entitlementID: Self.entitlementID,
            appDisplayName: "ConchTalk",
            companionAppNames: ["SnapKei"],
            revenueCatAPIKey: Bundle.main.object(forInfoDictionaryKey: "REVENUECAT_API_KEY") as? String,
            paywallFeatures: [
                PaywallFeature(id: "ai", icon: "sparkles", title: "Cloud AI", subtitle: nil),
                PaywallFeature(id: "sync", icon: "icloud", title: "Encrypted cloud sync", subtitle: nil),
                PaywallFeature(id: "multi", icon: "server.rack", title: "Multiple SSH connections", subtitle: nil),
            ],
            deviceName: "ConchTalk"
        )
        if let concreteAuth {
            self.gateway = GatewaySubscriptionService(authService: concreteAuth.gatewayAuthService, config: config, purchaseClient: purchaseClient)
        } else {
            self.gateway = GatewaySubscriptionService(authService: AuthService(keychainService: KeychainService()).gatewayAuthService, config: config, purchaseClient: purchaseClient)
        }
    }

    func startListening() {
        gateway.startListening()
    }

    func loadProducts() async {
        await gateway.loadProducts()
    }

    func purchase() async {
        await gateway.purchase()
    }

    func restore() async {
        await gateway.restore()
    }
}

private extension LLMGatewayKit.PurchaseState {
    var asConchTalkPurchaseState: PurchaseState {
        switch self {
        case .idle:
            return .idle
        case .purchasing:
            return .purchasing
        case .verifying:
            return .verifying
        case .success:
            return .success
        case .failed(let message):
            return .failed(message)
        }
    }
}
