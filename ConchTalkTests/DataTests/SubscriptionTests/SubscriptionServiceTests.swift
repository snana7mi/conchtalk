/// 文件说明：SubscriptionServiceTests，验证 SubscriptionService 的常量配置与购买状态实时转发。
import Testing
@testable import ConchTalk
import Foundation
import LLMGatewayKit

/// SuspendingPurchaseClient：可挂起的 PurchaseClient 测试替身。
/// restore() 挂起直到测试调用 finishRestore()，用于在挂起点断言中间购买状态。
nonisolated final class SuspendingPurchaseClient: PurchaseClient, @unchecked Sendable {
    private let lock = NSLock()
    private var restoreContinuation: CheckedContinuation<PurchaseCustomerInfo, Error>?
    private var _offering: PurchaseOffering?

    var offering: PurchaseOffering? {
        get { lock.lock(); defer { lock.unlock() }; return _offering }
        set { lock.lock(); defer { lock.unlock() }; _offering = newValue }
    }

    func currentOffering() async throws -> PurchaseOffering? { offering }

    func purchase(_ package: PurchasePackage) async throws -> PurchaseResult {
        PurchaseResult(userCancelled: true, entitlementIDs: [])
    }

    func restore() async throws -> PurchaseCustomerInfo {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            restoreContinuation = continuation
            lock.unlock()
        }
    }

    /// 释放挂起的 restore()，返回指定 entitlement 集合。
    func finishRestore(entitlements: Set<String>) {
        lock.lock()
        let continuation = restoreContinuation
        restoreContinuation = nil
        lock.unlock()
        continuation?.resume(returning: PurchaseCustomerInfo(activeEntitlementIDs: entitlements))
    }

    func customerInfoStream() -> AsyncStream<PurchaseCustomerInfo> {
        AsyncStream { $0.finish() }
    }
}

@Suite("SubscriptionService")
@MainActor
struct SubscriptionServiceTests {

    @Test("entitlementID 为 conchtalk Pro")
    func entitlementID() {
        #expect(SubscriptionService.entitlementID == "conchtalk Pro")
    }

    @Test("restore 进行中 purchaseState 实时呈现 verifying")
    func purchaseState_reflectsVerifying_duringRestore() async throws {
        let client = SuspendingPurchaseClient()
        let service = SubscriptionService(
            authService: AuthService(keychainService: MockKeychainService()),
            purchaseClient: client
        )
        #expect(service.purchaseState == .idle)

        // gateway.restore() 一进入即置 .verifying，随后挂起在 client.restore() 上
        let restoreTask = Task { await service.restore() }

        var sawVerifying = false
        for _ in 0..<100 {
            if service.purchaseState == .verifying {
                sawVerifying = true
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(sawVerifying, "restore 挂起期间 wrapper 应实时转发 verifying 中间态（修复前恒为 idle）")

        // 释放挂起：无有效 entitlement → 回到 idle
        client.finishRestore(entitlements: [])
        await restoreTask.value
        #expect(service.purchaseState == .idle)
    }

    @Test("displayPrice 转发 gateway loadProducts 结果")
    func displayPrice_forwardsGatewayValue_afterLoadProducts() async throws {
        let client = SuspendingPurchaseClient()
        client.offering = PurchaseOffering(packages: [
            PurchasePackage(id: "monthly", localizedPrice: "¥12.00")
        ])
        let service = SubscriptionService(
            authService: AuthService(keychainService: MockKeychainService()),
            purchaseClient: client
        )
        #expect(service.displayPrice == nil)

        await service.loadProducts()

        #expect(service.displayPrice == "¥12.00")
    }
}
