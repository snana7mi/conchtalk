/// 文件说明：SubscriptionService，ConchTalk 兼容层，委托 LLMGatewayKit 处理 RevenueCat 订阅流程。
import Foundation
import LLMGatewayKit

private typealias GatewaySubscriptionService = LLMGatewayKit.SubscriptionService

@Observable
final class SubscriptionService: SubscriptionServiceProtocol {
    private(set) var displayPrice: String?
    private(set) var purchaseState: PurchaseState = .idle

    static let entitlementID = "conchtalk Pro"

    private let gateway: GatewaySubscriptionService

    init(authService: AuthServiceProtocol) {
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
            self.gateway = GatewaySubscriptionService(authService: concreteAuth.gatewayAuthService, config: config)
        } else {
            self.gateway = GatewaySubscriptionService(authService: AuthService(keychainService: KeychainService()).gatewayAuthService, config: config)
        }
    }

    func startListening() {
        gateway.startListening()
    }

    func loadProducts() async {
        await gateway.loadProducts()
        syncFromGateway()
    }

    func purchase() async {
        await gateway.purchase()
        syncFromGateway()
    }

    func restore() async {
        await gateway.restore()
        syncFromGateway()
    }

    private func syncFromGateway() {
        displayPrice = gateway.displayPrice
        purchaseState = gateway.purchaseState.asConchTalkPurchaseState
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
