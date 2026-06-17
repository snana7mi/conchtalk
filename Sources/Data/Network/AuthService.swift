/// 文件说明：AuthService，ConchTalk 兼容层，委托 LLMGatewayKit 执行认证、账户与用量请求。
import Foundation
import LLMGatewayKit
import UIKit

private typealias GatewayAuthService = LLMGatewayKit.AuthService
private typealias GatewayAccountUser = LLMGatewayKit.AccountUser
private typealias GatewayUsageInfo = LLMGatewayKit.UsageInfo

// MARK: - Auth Models

struct AuthUser: Sendable {
    let id: String
    let email: String?
    let displayName: String?
    let tier: String
    let tierExpiresAt: String?
    let createdAt: String?
    let avatarURL: String?
    let memberNo: Int?
}

struct UsageInfo: Sendable {
    let budgetUsed: Int
    let budgetLimit: Int
    let percentage: Double
    let resetsAt: String?
    let tier: String
    let breakdown: [UsageBreakdown]

    var formattedBudgetUsed: String {
        String(format: "$%.2f", Double(budgetUsed) / 1_000_000.0)
    }

    var formattedBudgetLimit: String {
        String(format: "$%.2f", Double(budgetLimit) / 1_000_000.0)
    }
}

struct UsageBreakdown: Sendable {
    let appId: String
    let callCount: Int
    let costUsed: Int
}

// MARK: - AuthService

@Observable
final class AuthService: AuthServiceProtocol {
    private(set) var isLoggedIn = false
    private(set) var currentUser: AuthUser?
    private(set) var cachedAvatarData: Data?

    var cachedAppleSub: String? {
        gateway.cachedAppleSub
    }

    private let gateway: GatewayAuthService

    var gatewayAuthService: LLMGatewayKit.AuthService {
        gateway
    }

    init(keychainService: KeychainServiceProtocol) {
        let config = LLMGatewayKitConfig(
            baseURL: URL(string: "https://api.conch-talk.com")!,
            entitlementID: "conchtalk Pro",
            appDisplayName: "ConchTalk",
            companionAppNames: ["SnapKei"],
            revenueCatAPIKey: Bundle.main.object(forInfoDictionaryKey: "REVENUECAT_API_KEY") as? String,
            paywallFeatures: [
                PaywallFeature(id: "ai", icon: "sparkles", title: "Cloud AI", subtitle: nil),
                PaywallFeature(id: "sync", icon: "icloud", title: "Encrypted cloud sync", subtitle: nil),
                PaywallFeature(id: "multi", icon: "server.rack", title: "Multiple SSH connections", subtitle: nil),
            ],
            deviceName: UIDevice.current.name
        )
        try? LegacyMigrationHelper().migrateIfNeeded()
        self.gateway = GatewayAuthService(config: config)
        restoreSession()
    }

    func restoreSession() {
        gateway.restoreSession()
        syncFromGateway()
        if isLoggedIn {
            Task { try? await fetchAccount() }
        }
    }

    func authenticate(identityToken: Data, fullName: String?, appleSub: String) async throws {
        try await gateway.authenticate(identityToken: identityToken, fullName: fullName, appleSub: appleSub)
        syncFromGateway()
        try? await fetchAccount()
    }

    func validAccessToken() async throws -> String {
        try await gateway.validAccessToken()
    }

    func refreshAccessToken() async throws {
        try await gateway.refreshAccessToken()
        syncFromGateway()
    }

    func logout() async {
        await gateway.logout()
        SyncState.isEnabled = false
        SyncState.reset()
        syncFromGateway()
    }

    func deleteAccount() async throws {
        try await gateway.deleteAccount()
        SyncState.isEnabled = false
        SyncState.reset()
        syncFromGateway()
    }

    func fetchUsage() async throws -> UsageInfo {
        try await gateway.fetchUsage().asConchTalkUsage
    }

    func fetchAccount() async throws {
        try await gateway.fetchAccount()
        syncFromGateway()
    }

    func updateCurrentUser(_ user: AuthUser) {
        currentUser = user
        gateway.updateCurrentUser(user.asGatewayAccountUser)
        cacheTierAndUserID(user)
    }

    func uploadAvatar(imageData: Data) async throws -> String {
        let url = try await gateway.uploadAvatar(imageData: imageData, mimeType: "image/jpeg")
        cachedAvatarData = imageData
        syncFromGateway()
        return url
    }

    func loadAvatarDataIfNeeded() async -> Data? {
        let data = await gateway.loadAvatarDataIfNeeded()
        cachedAvatarData = data
        return data
    }

    private func syncFromGateway() {
        isLoggedIn = gateway.isLoggedIn
        currentUser = gateway.currentUser?.asConchTalkAuthUser
        cachedAvatarData = gateway.cachedAvatarData
        if let currentUser {
            cacheTierAndUserID(currentUser)
        } else {
            UserDefaults.standard.removeObject(forKey: "AuthService.cachedTier")
            UserDefaults.standard.removeObject(forKey: "AuthService.cachedUserID")
        }
    }

    private func cacheTierAndUserID(_ user: AuthUser) {
        UserDefaults.standard.set(user.tier, forKey: "AuthService.cachedTier")
        UserDefaults.standard.set(user.id, forKey: "AuthService.cachedUserID")
    }
}

// MARK: - Auth Errors

enum AuthError: LocalizedError {
    case notLoggedIn
    case sessionExpired
    case invalidURL
    case networkError
    case invalidResponse
    case serverError(String)
    case accountDeletionFailed

    var errorDescription: String? {
        switch self {
        case .notLoggedIn: return "Please sign in to use ConchTalk cloud service"
        case .sessionExpired: return "Session expired. Please sign in again"
        case .invalidURL: return "Invalid server URL"
        case .networkError: return "Network error"
        case .invalidResponse: return "Invalid server response"
        case .serverError(let msg): return "Server error: \(msg)"
        case .accountDeletionFailed: return "Failed to delete account"
        }
    }
}

private extension GatewayAccountUser {
    var asConchTalkAuthUser: AuthUser {
        AuthUser(
            id: id,
            email: email,
            displayName: displayName,
            tier: tier,
            tierExpiresAt: tierExpiresAt,
            createdAt: createdAt,
            avatarURL: avatarURL,
            memberNo: memberNo
        )
    }
}

private extension AuthUser {
    var asGatewayAccountUser: GatewayAccountUser {
        GatewayAccountUser(
            id: id,
            email: email,
            displayName: displayName,
            tier: tier,
            tierExpiresAt: tierExpiresAt,
            createdAt: createdAt,
            avatarURL: avatarURL,
            memberNo: memberNo
        )
    }
}

private extension GatewayUsageInfo {
    var asConchTalkUsage: UsageInfo {
        UsageInfo(
            budgetUsed: budgetUsed,
            budgetLimit: budgetLimit,
            percentage: percentage,
            resetsAt: resetsAt,
            tier: tier,
            breakdown: breakdown.map {
                UsageBreakdown(appId: $0.appId, callCount: $0.callCount, costUsed: $0.costUsed)
            }
        )
    }
}
