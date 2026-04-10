/// 文件说明：RelayTokenService，负责 relay token 的生成、吊销和状态查询。
import Foundation

/// RelayTokenResponse：token 创建 API 的响应。
struct RelayTokenResponse: Sendable {
    let id: String
    let token: String
    let installCommand: String
}

/// RelayStatusResponse：daemon 状态查询的响应。
struct RelayStatusResponse: Sendable {
    let status: String
    let tokenId: String?
    let name: String?
    let lastSeenAt: String?
    let lastSeenIp: String?

    var isDaemonOnline: Bool {
        guard let lastSeen = lastSeenAt,
              let date = try? Date(lastSeen, strategy: .iso8601) else { return false }
        // daemon 每 30 秒 ping，DO 写 D1 有延迟，放宽到 5 分钟
        return Date().timeIntervalSince(date) < 300
    }
}

/// RelayError：relay 相关操作错误。
enum RelayError: LocalizedError {
    case notAuthenticated
    case tokenNotFound
    case budgetExceeded
    case daemonOffline
    case networkError(String)
    case serverError(Int)

    var errorDescription: String? {
        switch self {
        case .notAuthenticated: return "Not authenticated"
        case .tokenNotFound: return "Relay token not found"
        case .budgetExceeded: return "Daily budget exceeded"
        case .daemonOffline: return "Daemon is offline"
        case .networkError(let msg): return "Network error: \(msg)"
        case .serverError(let code): return "Server error: \(code)"
        }
    }
}

/// RelayTokenService：管理 relay daemon token 的生命周期。
final class RelayTokenService: Sendable {
    private let baseURL = "https://api.conch-talk.com"
    private let authService: AuthServiceProtocol

    init(authService: AuthServiceProtocol) {
        self.authService = authService
    }

    /// 为指定服务器生成 relay token。
    func createToken(serverID: UUID, name: String?) async throws -> RelayTokenResponse {
        let url = URL(string: "\(baseURL)/relay/token")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        try await setAuthHeader(&request)

        let body: [String: Any] = [
            "server_id": serverID.uuidString,
            "name": name ?? ""
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        try checkResponse(response)

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        return RelayTokenResponse(
            id: json["id"] as? String ?? "",
            token: json["token"] as? String ?? "",
            installCommand: json["install_command"] as? String ?? ""
        )
    }

    /// 吊销指定 token。
    func revokeToken(tokenId: String) async throws {
        let url = URL(string: "\(baseURL)/relay/token/\(tokenId)")!
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        try await setAuthHeader(&request)

        let (_, response) = try await URLSession.shared.data(for: request)
        try checkResponse(response)
    }

    /// 查询指定服务器的 relay 状态。
    func getStatus(serverID: UUID) async throws -> RelayStatusResponse {
        let url = URL(string: "\(baseURL)/relay/status/\(serverID.uuidString)")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        try await setAuthHeader(&request)

        let (data, response) = try await URLSession.shared.data(for: request)
        try checkResponse(response)

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        return RelayStatusResponse(
            status: json["status"] as? String ?? "unknown",
            tokenId: json["token_id"] as? String,
            name: json["name"] as? String,
            lastSeenAt: json["last_seen_at"] as? String,
            lastSeenIp: json["last_seen_ip"] as? String
        )
    }

    private func setAuthHeader(_ request: inout URLRequest) async throws {
        let token = try await authService.validAccessToken()
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }

    private func checkResponse(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw RelayError.networkError("Invalid response")
        }
        switch http.statusCode {
        case 200...299: return
        case 401: throw RelayError.notAuthenticated
        case 404: throw RelayError.tokenNotFound
        case 429: throw RelayError.budgetExceeded
        default: throw RelayError.serverError(http.statusCode)
        }
    }
}
