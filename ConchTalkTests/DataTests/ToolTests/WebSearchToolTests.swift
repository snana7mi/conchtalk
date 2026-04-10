/// 文件说明：WebSearchToolTests，验证 WebSearchTool 的参数校验、安全分级与响应格式化。
import Testing
@testable import ConchTalk
import Foundation

@Suite("WebSearchTool", .serialized)
struct WebSearchToolTests {
    // MARK: - Stub

    /// 模拟 AuthService，返回固定 token。
    private final class StubAuthService: AuthServiceProtocol, @unchecked Sendable {
        let tokenToReturn: String
        var isLoggedIn: Bool { true }
        var currentUser: AuthUser? { nil }
        init(token: String = "test-jwt-token") { self.tokenToReturn = token }
        func validAccessToken() async throws -> String { tokenToReturn }
        func refreshAccessToken() async throws {}
        func updateCurrentUser(_ user: AuthUser) {}
        func fetchAccount() async throws {}
    }

    /// 模拟 URLSession 响应，用于拦截 HTTP 请求。
    private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var responseData: Data?
        nonisolated(unsafe) static var responseStatusCode: Int = 200
        nonisolated(unsafe) static var lastRequest: URLRequest?
        /// URLProtocol 传递后 httpBody 可能被置空，需在 startLoading 中单独保存。
        nonisolated(unsafe) static var lastRequestBody: Data?

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            Self.lastRequest = request
            Self.lastRequestBody = request.httpBody ?? request.httpBodyStream.flatMap { stream in
                stream.open()
                defer { stream.close() }
                var data = Data()
                let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
                defer { buffer.deallocate() }
                while stream.hasBytesAvailable {
                    let count = stream.read(buffer, maxLength: 4096)
                    if count > 0 { data.append(buffer, count: count) }
                    else { break }
                }
                return data
            }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: Self.responseStatusCode,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if let data = Self.responseData {
                client?.urlProtocol(self, didLoad: data)
            }
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func makeTool(token: String = "test-jwt") -> WebSearchTool {
        WebSearchTool(authService: StubAuthService(token: token), session: makeSession())
    }

    private func braveResponse(snippets: [String] = ["Swift is a programming language."]) -> Data {
        let json: [String: Any] = [
            "grounding": [
                "generic": [
                    [
                        "url": "https://example.com",
                        "title": "Example",
                        "snippets": snippets,
                    ]
                ],
                "map": [] as [[String: Any]],
            ],
            "sources": [
                "https://example.com": [
                    "title": "Example",
                    "hostname": "example.com",
                    "age": ["2 days ago"],
                ]
            ],
        ]
        return try! JSONSerialization.data(withJSONObject: json)
    }

    // MARK: - 元信息

    @Test("name is web_search")
    func name() {
        let tool = makeTool()
        #expect(tool.name == "web_search")
    }

    @Test("safety is always safe")
    func safety() {
        let tool = makeTool()
        #expect(tool.validateSafety(arguments: ["query": "test"]) == .safe)
    }

    @Test("parametersSchema has required query")
    func schema() {
        let tool = makeTool()
        let required = tool.parametersSchema["required"] as? [String]
        #expect(required == ["query"])
    }

    // MARK: - 参数校验

    @Test("missing query throws missingParameter")
    func missingQuery() async {
        let tool = makeTool()
        let mockSSH = MockSSHClient()
        await #expect(throws: ToolError.self) {
            _ = try await tool.execute(arguments: [:], sshClient: mockSSH)
        }
    }

    @Test("empty query throws invalidArguments")
    func emptyQuery() async {
        let tool = makeTool()
        let mockSSH = MockSSHClient()
        await #expect(throws: ToolError.self) {
            _ = try await tool.execute(arguments: ["query": ""], sshClient: mockSSH)
        }
    }

    // MARK: - 请求构建

    @Test("sends correct request to cloud proxy")
    func requestFormat() async throws {
        let tool = makeTool(token: "my-jwt")
        StubURLProtocol.responseData = braveResponse()
        StubURLProtocol.responseStatusCode = 200

        let mockSSH = MockSSHClient()
        _ = try await tool.execute(
            arguments: ["query": "swift language", "country": "US", "freshness": "pw", "count": 10],
            sshClient: mockSSH
        )

        let request = try #require(StubURLProtocol.lastRequest)
        #expect(request.url?.absoluteString == "https://api.conch-talk.com/api/web-search")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer my-jwt")
        #expect(request.httpMethod == "POST")

        let bodyData = try #require(StubURLProtocol.lastRequestBody)
        let body = try JSONSerialization.jsonObject(with: bodyData) as! [String: Any]
        #expect(body["query"] as? String == "swift language")
        #expect(body["country"] as? String == "US")
        #expect(body["freshness"] as? String == "pw")
        #expect(body["count"] as? Int == 10)
    }

    // MARK: - 响应格式化

    @Test("formats grounding snippets into readable output")
    func responseFormatting() async throws {
        let tool = makeTool()
        StubURLProtocol.responseData = braveResponse(snippets: ["Hello world"])
        StubURLProtocol.responseStatusCode = 200

        let mockSSH = MockSSHClient()
        let result = try await tool.execute(arguments: ["query": "test"], sshClient: mockSSH)

        #expect(result.output.contains("Example"))
        #expect(result.output.contains("https://example.com"))
        #expect(result.output.contains("Hello world"))
        #expect(result.output.contains("example.com"))
        #expect(result.isSuccess)
    }

    // MARK: - 错误处理

    @Test("HTTP error returns failure result")
    func httpError() async throws {
        let tool = makeTool()
        StubURLProtocol.responseData = Data("{\"error\": \"rate limited\"}".utf8)
        StubURLProtocol.responseStatusCode = 429

        let mockSSH = MockSSHClient()
        let result = try await tool.execute(arguments: ["query": "test"], sshClient: mockSSH)

        #expect(!result.isSuccess)
        #expect(result.output.contains("429"))
    }
}
