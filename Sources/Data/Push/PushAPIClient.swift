/// 文件说明：PushAPIClient，向托管后端 /push/* 发送鉴权请求（注册 token / 预约 / check-in）。
import Foundation

/// PushAPIClient：薄 HTTP 客户端，复用 AuthService 的 Bearer JWT 调用 api.conch-talk.com。
nonisolated final class PushAPIClient: Sendable {
    private let session: URLSession
    private let tokenProvider: @Sendable () async throws -> String
    private let baseURL = "https://api.conch-talk.com"

    init(session: URLSession = .shared, tokenProvider: @escaping @Sendable () async throws -> String) {
        self.session = session
        self.tokenProvider = tokenProvider
    }

    func registerToken(apnsToken: String, environment: String, installID: String) async throws {
        try await send("POST", "/push/token", ["apnsToken": apnsToken, "environment": environment, "installID": installID])
    }

    func deleteToken(installID: String) async throws {
        try await send("DELETE", "/push/token", ["installID": installID])
    }

    func schedule(scheduleID: String, title: String, body: String, serverID: String, fireAfterSeconds: Int) async throws {
        try await send("POST", "/push/schedule", ["scheduleID": scheduleID, "title": title, "body": body, "serverID": serverID, "fireAfterSeconds": fireAfterSeconds])
    }

    func checkin(scheduleID: String) async throws {
        try await send("POST", "/push/checkin", ["scheduleID": scheduleID])
    }

    func checkinAll() async throws {
        try await send("POST", "/push/checkin", ["all": true])
    }

    private func send(_ method: String, _ path: String, _ json: [String: Any]) async throws {
        let token = try await tokenProvider()
        var request = URLRequest(url: URL(string: "\(baseURL)\(path)")!)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: json)
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }
}
