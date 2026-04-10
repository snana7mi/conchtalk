/// 文件说明：AuthService，负责 Apple 登录认证、JWT 令牌管理与用户信息获取。
import Foundation
import RevenueCat
import UIKit

// MARK: - Auth Models

struct AuthUser: Sendable {
    let id: String
    let email: String?
    let displayName: String?
    let tier: String
    let tierExpiresAt: String?
    let createdAt: String?
    let avatarURL: String?
}

struct AuthTokenResponse: Sendable {
    let accessToken: String
    let refreshToken: String
    let user: AuthUser?
}

struct UsageInfo: Sendable {
    let budgetUsed: Int       // 微美元
    let budgetLimit: Int      // 微美元
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

/// AuthService：管理用户认证状态、令牌刷新与账户操作。
@Observable
final class AuthService: AuthServiceProtocol {
    private(set) var isLoggedIn: Bool = false
    private(set) var currentUser: AuthUser? = nil

    /// 缓存的用户头像数据，避免重复网络请求。avatarURL 变化时自动失效。
    private(set) var cachedAvatarData: Data? = nil
    /// 当前缓存对应的 avatarURL，用于判断是否需要重新下载。
    private var cachedAvatarURL: String? = nil

    /// 本地缓存的用户 tier 和 ID，用于 session restore 时 currentUser 尚未加载时的同步读取。
    private static let cachedTierKey = "AuthService.cachedTier"
    private static let cachedUserIDKey = "AuthService.cachedUserID"
    private static let cachedAppleSubKey = "AuthService.cachedAppleSub"

    /// 缓存的 Apple 用户标识符，用于 RevenueCat appUserID。
    var cachedAppleSub: String? {
        UserDefaults.standard.string(forKey: Self.cachedAppleSubKey)
    }

    private let keychainService: KeychainServiceProtocol
    private let session: URLSession
    private let baseURL = "https://api.conch-talk.com"
    private var refreshTask: Task<Void, Error>?

    init(keychainService: KeychainServiceProtocol) {
        self.keychainService = keychainService
        self.session = URLSession.shared
        restoreSession()
    }

    // MARK: - Session Restore

    /// restoreSession：App 启动时从 Keychain 恢复登录状态。
    func restoreSession() {
        if let _ = try? keychainService.getAccessToken(),
           let _ = try? keychainService.getRefreshToken() {
            isLoggedIn = true
            // 后台拉取最新用户信息
            Task { try? await fetchAccount() }
        }
    }

    // MARK: - Apple Sign In

    /// authenticate：用 Apple identity token 换取 JWT pair。
    /// - Parameter appleSub: Apple 用户标识符（ASAuthorizationAppleIDCredential.user），用于 RevenueCat。
    func authenticate(identityToken: Data, fullName: String?, appleSub: String) async throws {
        guard let tokenString = String(data: identityToken, encoding: .utf8) else {
            throw AuthError.invalidResponse
        }

        let deviceName = UIDevice.current.name

        var body: [String: Any] = [
            "identityToken": tokenString,
            "deviceName": deviceName,
        ]
        if let fullName, !fullName.isEmpty {
            body["displayName"] = fullName
        }

        let response = try await postJSON(path: "/auth/apple", body: body)
        let tokenResponse = try parseTokenResponse(from: response)
        try storeTokens(tokenResponse)

        isLoggedIn = true
        currentUser = tokenResponse.user
        UserDefaults.standard.set(appleSub, forKey: Self.cachedAppleSubKey)

        // 后台拉取最新用户信息
        Task { try? await fetchAccount() }
    }

    // MARK: - Token Management

    /// validAccessToken：获取有效的 access token，过期时自动刷新。
    func validAccessToken() async throws -> String {
        guard let accessToken = try keychainService.getAccessToken() else {
            throw AuthError.notLoggedIn
        }

        // 在过期前 60 秒提前刷新
        if let expiry = try keychainService.getTokenExpiry(),
           expiry.timeIntervalSinceNow < 60 {
            try await refreshAccessToken()
            guard let newToken = try keychainService.getAccessToken() else {
                throw AuthError.notLoggedIn
            }
            return newToken
        }

        return accessToken
    }

    /// refreshAccessToken：使用 refresh token 获取新的 token pair。
    /// Single-flight：多个并发调用共享同一个刷新请求，避免一次性 refresh token 被重复消费。
    func refreshAccessToken() async throws {
        if let existing = refreshTask {
            return try await existing.value
        }

        let task = Task {
            defer { refreshTask = nil }
            try await performRefresh()
        }
        refreshTask = task
        try await task.value
    }

    private func performRefresh() async throws {
        guard let refreshToken = try keychainService.getRefreshToken() else {
            await logout()
            throw AuthError.notLoggedIn
        }

        let deviceName = UIDevice.current.name

        let body: [String: Any] = [
            "refreshToken": refreshToken,
            "deviceName": deviceName,
        ]

        do {
            let response = try await postJSON(path: "/auth/refresh", body: body)
            let tokenResponse = try parseTokenResponse(from: response)
            try storeTokens(tokenResponse)
        } catch let error as URLError {
            // 网络层错误（超时、连接中断等）：保留本地会话，原样抛出
            throw error
        } catch {
            // 服务端明确拒绝（401、token 无效等）：清除本地会话
            await logout()
            throw AuthError.sessionExpired
        }
    }

    // MARK: - Logout & Account

    /// logout：清除所有认证令牌并重置登录状态。
    func logout() async {
        _ = try? keychainService.deleteAllAuthTokens()
        isLoggedIn = false
        currentUser = nil
        cachedAvatarData = nil
        cachedAvatarURL = nil
        UserDefaults.standard.removeObject(forKey: Self.cachedTierKey)
        UserDefaults.standard.removeObject(forKey: Self.cachedUserIDKey)
        UserDefaults.standard.removeObject(forKey: Self.cachedAppleSubKey)
        // 登出时重置 RC 身份为匿名，防止 Restore Purchases 作用于旧用户
        // 仅在 RevenueCat 已配置时调用，未配置时访问 Purchases.shared 会 fatalError
        if Purchases.isConfigured {
            _ = try? await Purchases.shared.logOut()
        }
        // 重置同步状态（disabledByUserID 保留，per-user 语义由 auto-enable 按 ID 判断）
        SyncState.isEnabled = false
        SyncState.reset()
    }

    /// deleteAccount：向后端请求删除账户并清除本地状态。
    func deleteAccount() async throws {
        let token = try await validAccessToken()

        var request = URLRequest(url: URL(string: "\(baseURL)/auth/account")!)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            throw AuthError.accountDeletionFailed
        }

        await logout()
    }

    // MARK: - Usage

    /// fetchUsage：获取当前用户的用量信息。
    func fetchUsage() async throws -> UsageInfo {
        let token = try await validAccessToken()

        var request = URLRequest(url: URL(string: "\(baseURL)/usage")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            throw AuthError.networkError
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let budgetUsed = json["budgetUsed"] as? Int,
              let budgetLimit = json["budgetLimit"] as? Int,
              let percentage = json["percentage"] as? Double,
              let tier = json["tier"] as? String else {
            throw AuthError.invalidResponse
        }

        let breakdownArray = json["breakdown"] as? [[String: Any]] ?? []
        let breakdown = breakdownArray.compactMap { item -> UsageBreakdown? in
            guard let appId = item["appId"] as? String,
                  let callCount = item["callCount"] as? Int,
                  let costUsed = item["costUsed"] as? Int else { return nil }
            return UsageBreakdown(appId: appId, callCount: callCount, costUsed: costUsed)
        }

        return UsageInfo(
            budgetUsed: budgetUsed,
            budgetLimit: budgetLimit,
            percentage: percentage,
            resetsAt: json["resetsAt"] as? String,
            tier: tier,
            breakdown: breakdown
        )
    }

    /// fetchAccount：获取完整用户信息 + 用量，更新 currentUser。
    func fetchAccount() async throws {
        let token = try await validAccessToken()

        var request = URLRequest(url: URL(string: "\(baseURL)/account")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            throw AuthError.networkError
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let userDict = json["user"] as? [String: Any],
              let userId = userDict["id"] as? String,
              let tier = userDict["tier"] as? String else {
            throw AuthError.invalidResponse
        }

        currentUser = AuthUser(
            id: userId,
            email: userDict["email"] as? String,
            displayName: userDict["displayName"] as? String,
            tier: tier,
            tierExpiresAt: userDict["tierExpiresAt"] as? String,
            createdAt: userDict["createdAt"] as? String,
            avatarURL: userDict["avatarURL"] as? String
        )
        UserDefaults.standard.set(tier, forKey: Self.cachedTierKey)
        UserDefaults.standard.set(userId, forKey: Self.cachedUserIDKey)
        // 恢复 cachedAppleSub（重装 app 后 UserDefaults 丢失，从后端补回）
        if let appleSub = userDict["appleSub"] as? String {
            UserDefaults.standard.set(appleSub, forKey: Self.cachedAppleSubKey)
        }
    }

    /// updateCurrentUser：外部传入新的 AuthUser 以刷新本地状态（用于订阅验证后更新 tier）。
    func updateCurrentUser(_ user: AuthUser) {
        currentUser = user
        UserDefaults.standard.set(user.tier, forKey: Self.cachedTierKey)
        UserDefaults.standard.set(user.id, forKey: Self.cachedUserIDKey)
    }

    // MARK: - Avatar

    /// uploadAvatar：上传用户头像到云端，返回头像 URL。
    func uploadAvatar(imageData: Data) async throws -> String {
        let token = try await validAccessToken()
        let boundary = UUID().uuidString

        var request = URLRequest(url: URL(string: "\(baseURL)/account/avatar")!)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"avatar\"; filename=\"avatar.jpg\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
        body.append(imageData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            throw AuthError.serverError("Avatar upload failed")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let avatarURL = json["avatarURL"] as? String else {
            throw AuthError.invalidResponse
        }

        // 更新本地用户信息与头像缓存
        if let user = currentUser {
            currentUser = AuthUser(
                id: user.id, email: user.email, displayName: user.displayName,
                tier: user.tier, tierExpiresAt: user.tierExpiresAt,
                createdAt: user.createdAt, avatarURL: avatarURL
            )
        }
        cachedAvatarData = imageData
        cachedAvatarURL = avatarURL

        return avatarURL
    }

    // MARK: - Avatar Cache

    /// loadAvatarDataIfNeeded：按需下载头像数据并缓存，URL 未变化时直接返回缓存。
    func loadAvatarDataIfNeeded() async -> Data? {
        guard let urlStr = currentUser?.avatarURL, !urlStr.isEmpty else { return nil }
        // 缓存命中
        if urlStr == cachedAvatarURL, let data = cachedAvatarData { return data }
        // 下载
        guard let url = URL(string: urlStr),
              let (data, _) = try? await session.data(from: url) else { return nil }
        cachedAvatarData = data
        cachedAvatarURL = urlStr
        return data
    }

    // MARK: - Private Helpers

    /// storeTokens：将令牌响应持久化到 Keychain（固定 15 分钟过期）。
    private func storeTokens(_ response: AuthTokenResponse) throws {
        try keychainService.saveAccessToken(response.accessToken)
        try keychainService.saveRefreshToken(response.refreshToken)
        let expiry = Date().addingTimeInterval(15 * 60)
        try keychainService.saveTokenExpiry(expiry)
    }

    /// postJSON：发送 POST 请求并返回响应数据。
    private func postJSON(path: String, body: [String: Any]) async throws -> Data {
        guard let url = URL(string: "\(baseURL)\(path)") else {
            throw AuthError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 15

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AuthError.networkError
        }

        guard (200...299).contains(http.statusCode) else {
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let errorMsg = json["error"] as? String {
                    throw AuthError.serverError(errorMsg)
                }
                if let errorObj = json["error"] as? [String: Any],
                   let message = errorObj["message"] as? String {
                    throw AuthError.serverError(message)
                }
            }
            throw AuthError.serverError("HTTP \(http.statusCode)")
        }

        return data
    }

    /// parseTokenResponse：解析后端令牌响应。
    private func parseTokenResponse(from data: Data) throws -> AuthTokenResponse {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["accessToken"] as? String,
              let refreshToken = json["refreshToken"] as? String else {
            throw AuthError.invalidResponse
        }

        // user 字段可选（login 有，refresh 无）
        var user: AuthUser? = nil
        if let userDict = json["user"] as? [String: Any],
           let userId = userDict["id"] as? String,
           let tier = userDict["tier"] as? String {
            user = AuthUser(
                id: userId,
                email: userDict["email"] as? String,
                displayName: userDict["displayName"] as? String,
                tier: tier,
                tierExpiresAt: userDict["tierExpiresAt"] as? String,
                createdAt: userDict["createdAt"] as? String,
                avatarURL: userDict["avatarURL"] as? String
            )
        }

        return AuthTokenResponse(
            accessToken: accessToken,
            refreshToken: refreshToken,
            user: user
        )
    }
}

// MARK: - Auth Errors

/// AuthError：定义认证流程中的错误类型。
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
