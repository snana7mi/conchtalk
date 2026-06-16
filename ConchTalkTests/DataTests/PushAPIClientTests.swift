/// 文件说明：PushAPIClientTests，验证 /push/* 请求构造与鉴权头。
import Testing
import Foundation
@testable import ConchTalk

@Suite("PushAPIClient")
struct PushAPIClientTests {
    /// 截获请求的 URLProtocol。
    final class CapturingProtocol: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var lastRequest: URLRequest?
        nonisolated(unsafe) static var lastBody: Data?
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            Self.lastRequest = request
            Self.lastBody = request.httpBodyStream.flatMap { stream in
                stream.open(); defer { stream.close() }
                var data = Data(); var buf = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable { let n = stream.read(&buf, maxLength: buf.count); if n <= 0 { break }; data.append(buf, count: n) }
                return data
            } ?? request.httpBody
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("{\"ok\":true}".utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private func makeClient() -> PushAPIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CapturingProtocol.self]
        return PushAPIClient(session: URLSession(configuration: config), tokenProvider: { "test-jwt" })
    }

    @Test("registerToken 发 POST /push/token 带 Bearer + JSON 体")
    func registerToken() async throws {
        CapturingProtocol.lastRequest = nil
        try await makeClient().registerToken(apnsToken: "deadbeef", environment: "sandbox", installID: "i1")
        let req = try #require(CapturingProtocol.lastRequest)
        #expect(req.url?.absoluteString == "https://api.conch-talk.com/push/token")
        #expect(req.httpMethod == "POST")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer test-jwt")
        let body = try JSONSerialization.jsonObject(with: try #require(CapturingProtocol.lastBody)) as? [String: Any]
        #expect(body?["apnsToken"] as? String == "deadbeef")
        #expect(body?["installID"] as? String == "i1")
    }

    @Test("schedule 发 POST /push/schedule")
    func schedule() async throws {
        CapturingProtocol.lastRequest = nil
        try await makeClient().schedule(scheduleID: "s1", title: "prod", body: "审批", serverID: "srv", fireAfterSeconds: 45)
        #expect(CapturingProtocol.lastRequest?.url?.absoluteString == "https://api.conch-talk.com/push/schedule")
    }
}
