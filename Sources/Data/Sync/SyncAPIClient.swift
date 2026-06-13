/// 文件说明：SyncAPIClient，封装与后端 /sync/* 接口的 HTTP 通信。
import Foundation

/// SyncAPIClient：负责云同步 API 的网络请求。
final class SyncAPIClient: SyncAPIClientProtocol, Sendable {
    private let baseURL: String
    private let authService: AuthService
    private let session: URLSession

    /// - Parameter baseURL: API 根地址，默认生产环境；联调时可指向测试服务器上的 S2 实例。
    init(authService: AuthService, baseURL: String = "https://api.conch-talk.com") {
        self.authService = authService
        self.baseURL = baseURL
        self.session = URLSession.shared
    }

    // MARK: - Push

    struct PushRequest: Encodable {
        let key_generation: Int
        let device_id: String
        let entries: [PushEntry]
    }

    struct PushEntry: Encodable {
        let entity_type: String
        let entity_id: String
        let modified_at: String
        let data: String // base64
    }

    struct PushResponse: Decodable {
        let success: Bool
        let stored_entries: Int
        let pruned_count: Int
    }

    func push(_ request: PushRequest) async throws -> PushResponse {
        let data = try JSONEncoder().encode(request)
        return try await performRequest(method: "PUT", path: "/sync/push", body: data)
    }

    // MARK: - Pull

    struct PullEntry: Decodable {
        /// S2 线上响应不含 seq（entries 形态与旧版一致）；满页续拉靠 next_cursor.seq。
        let seq: Int64?
        let entity_type: String
        let entity_id: String
        let modified_at: String   // 保留：仅供调试观察，不再参与游标计算
        let device_id: String
        let data: String // base64（单条实体的加密 blob）
    }

    /// S2 seq 游标：满页时 next_cursor 为 { seq }，不满页为 null。
    struct PullSeqCursor: Decodable, Equatable, Sendable {
        let seq: Int64
    }

    struct PullResponse: Decodable {
        let entries: [PullEntry]
        let next_cursor: PullSeqCursor?   // 满页续拉起点；nil 表示已到末页
    }

    /// 拉取增量：返回 seq > sinceSeq 且 device_id != 请求方的条目，按 seq 升序，最多 limit 条。
    /// 查询参数与 S2 终稿对齐：`seq`（非 since_seq）。
    func pull(sinceSeq: Int64, deviceId: String, limit: Int = 100) async throws -> PullResponse {
        let query = "seq=\(sinceSeq)&device_id=\(deviceId)&limit=\(limit)"
        return try await performRequest(method: "GET", path: "/sync/pull?\(query)", body: nil)
    }

    // MARK: - Status

    struct StatusResponse: Decodable {
        let storage_bytes: Int
        let last_push_at: String?
        let entry_count: Int
        let key_generation: Int
    }

    func status() async throws -> StatusResponse {
        try await performRequest(method: "GET", path: "/sync/status", body: nil)
    }

    // MARK: - Delete

    struct DeleteResponse: Decodable {
        let success: Bool
        let deleted_entries: Int
    }

    func deleteAll() async throws -> DeleteResponse {
        try await performRequest(method: "DELETE", path: "/sync/data", body: nil)
    }

    // MARK: - Private

    private func performRequest<T: Decodable>(method: String, path: String, body: Data?) async throws -> T {
        let token = try await authService.validAccessToken()
        var request = URLRequest(url: URL(string: "\(baseURL)\(path)")!)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SyncAPIError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200...299:
            return try JSONDecoder().decode(T.self, from: data)
        case 403:
            throw SyncAPIError.notPaidTier
        case 409:
            throw SyncAPIError.keyGenerationMismatch
        default:
            let message = (try? JSONDecoder().decode([String: String].self, from: data))?["error"] ?? "Unknown error"
            throw SyncAPIError.serverError(statusCode: httpResponse.statusCode, message: message)
        }
    }
}

/// SyncAPIClientProtocol：云同步 API 通信契约，供 SyncService 依赖注入与测试 mock。
/// 协议方法不带默认参数（limit 由调用方显式传递）；status() 不被 SyncService 使用，不入协议。
protocol SyncAPIClientProtocol: Sendable {
    func push(_ request: SyncAPIClient.PushRequest) async throws -> SyncAPIClient.PushResponse
    func pull(sinceSeq: Int64, deviceId: String, limit: Int) async throws -> SyncAPIClient.PullResponse
    func deleteAll() async throws -> SyncAPIClient.DeleteResponse
}

/// SyncAPIError：同步 API 错误类型。
enum SyncAPIError: LocalizedError, Equatable {
    case invalidResponse
    case notPaidTier
    case keyGenerationMismatch
    case serverError(statusCode: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "Invalid server response"
        case .notPaidTier: "Cloud sync requires a paid subscription"
        case .keyGenerationMismatch: "Encryption key has been reset on another device"
        case .serverError(let code, let msg): "Server error \(code): \(msg)"
        }
    }

    static func == (lhs: SyncAPIError, rhs: SyncAPIError) -> Bool {
        switch (lhs, rhs) {
        case (.keyGenerationMismatch, .keyGenerationMismatch): true
        case (.notPaidTier, .notPaidTier): true
        case (.invalidResponse, .invalidResponse): true
        case (.serverError(let a, _), .serverError(let b, _)): a == b
        default: false
        }
    }
}
