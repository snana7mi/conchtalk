/// 文件说明：SubscriptionService，基于 RevenueCat 管理订阅生命周期。
import Foundation
import RevenueCat

/// SubscriptionService：
/// 通过 RevenueCat SDK 处理购买、恢复、状态监听，
/// 购买成功后刷新后端 tier（RC webhook 异步更新后端，客户端轮询确认）。
@Observable
final class SubscriptionService: SubscriptionServiceProtocol {

    private(set) var displayPrice: String?
    private(set) var purchaseState: PurchaseState = .idle

    private let authService: AuthServiceProtocol

    /// RevenueCat Entitlement ID。
    static let entitlementID = "conchtalk Pro"

    init(authService: AuthServiceProtocol) {
        self.authService = authService
    }

    // MARK: - Listening

    /// App 启动时调用。用 RC 的 customerInfoStream 监听订阅状态变化，
    /// 变化时刷新后端 AuthUser。
    func startListening() {
        Task { [weak self] in
            for await customerInfo in Purchases.shared.customerInfoStream {
                guard let self else { return }
                let isActive = customerInfo.entitlements[Self.entitlementID]?.isActive == true
                let currentTier = authService.currentUser?.tier ?? "free"
                // 只在状态变化时刷新
                if (isActive && currentTier != "paid") || (!isActive && currentTier == "paid") {
                    try? await authService.fetchAccount()
                }
            }
        }
    }

    // MARK: - Products

    /// 从 RevenueCat 加载当前 Offering 的展示价格。
    func loadProducts() async {
        do {
            let offerings = try await Purchases.shared.offerings()
            if let package = offerings.current?.availablePackages.first {
                displayPrice = package.localizedPriceString
            }
        } catch {
            displayPrice = nil
        }
    }

    // MARK: - Purchase

    /// 通过 RevenueCat 发起购买。未登录时跳过（避免购买成功但无法同步 tier）。
    func purchase() async {
        guard authService.isLoggedIn else {
            purchaseState = .failed(String(localized: "Please sign in first", bundle: LanguageSettings.currentBundle))
            return
        }

        do {
            let offerings = try await Purchases.shared.offerings()
            guard let package = offerings.current?.availablePackages.first else { return }

            purchaseState = .purchasing
            let result = try await Purchases.shared.purchase(package: package)

            if result.userCancelled {
                purchaseState = .idle
                return
            }

            // 购买成功，等待后端 webhook 更新 tier
            purchaseState = .verifying
            let synced = await waitForTierSync(expectedTier: "paid")
            purchaseState = synced ? .success : .failed(String(localized: "Sync timeout", bundle: LanguageSettings.currentBundle))
        } catch {
            purchaseState = .failed(error.localizedDescription)
        }
    }

    // MARK: - Restore

    /// 恢复购买。未登录时跳过 tier 同步，仅恢复 RC 侧权益。
    func restore() async {
        do {
            purchaseState = .verifying
            let customerInfo = try await Purchases.shared.restorePurchases()
            let isActive = customerInfo.entitlements[Self.entitlementID]?.isActive == true
            if isActive {
                if authService.isLoggedIn {
                    let synced = await waitForTierSync(expectedTier: "paid")
                    purchaseState = synced ? .success : .failed(String(localized: "Sync timeout", bundle: LanguageSettings.currentBundle))
                } else {
                    // RC 侧权益已恢复，但未登录无法同步后端 tier，付费功能需登录后激活
                    purchaseState = .failed(String(localized: "Restore successful. Please sign in to activate paid features.", bundle: LanguageSettings.currentBundle))
                }
            } else {
                purchaseState = .idle
            }
        } catch {
            purchaseState = .failed(error.localizedDescription)
        }
    }

    // MARK: - Tier Sync

    /// 轮询后端 tier 状态，等待 webhook 更新完成。
    /// 最多重试 5 次，间隔 1 秒。
    @discardableResult
    private func waitForTierSync(expectedTier: String) async -> Bool {
        for _ in 0..<5 {
            try? await Task.sleep(for: .seconds(1))
            try? await authService.fetchAccount()
            if authService.currentUser?.tier == expectedTier {
                return true
            }
        }
        return false
    }
}
