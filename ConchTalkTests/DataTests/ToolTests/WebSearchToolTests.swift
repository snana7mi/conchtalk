/// 文件说明：WebSearchToolTests，验证多搜索提供商直连请求、动态启停与响应格式化。
import Testing
@testable import ConchTalk
import Foundation

@Suite("WebSearchTool", .serialized)
struct WebSearchToolTests {
    private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var responseData = Data()
        nonisolated(unsafe) static var responseStatusCode = 200
        nonisolated(unsafe) static var lastRequest: URLRequest?
        nonisolated(unsafe) static var lastRequestBody: Data?

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            Self.lastRequest = request
            Self.lastRequestBody = request.httpBody ?? request.httpBodyStream.flatMap { stream in
                stream.open()
                defer { stream.close() }
                var data = Data()
                let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4_096)
                defer { buffer.deallocate() }
                while stream.hasBytesAvailable {
                    let count = stream.read(buffer, maxLength: 4_096)
                    if count > 0 {
                        data.append(buffer, count: count)
                    } else {
                        break
                    }
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
            client?.urlProtocol(self, didLoad: Self.responseData)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func makeTool(
        provider: WebSearchProvider = .brave,
        enabled: Bool = true,
        apiKey: String = "test-key"
    ) -> WebSearchTool {
        let settings = WebSearchSettings(
            isEnabled: enabled,
            provider: provider,
            apiKeys: [provider: apiKey]
        )
        return WebSearchTool(settingsProvider: { settings }, session: makeSession())
    }

    private func resetStub(data: Data, statusCode: Int = 200) {
        StubURLProtocol.responseData = data
        StubURLProtocol.responseStatusCode = statusCode
        StubURLProtocol.lastRequest = nil
        StubURLProtocol.lastRequestBody = nil
    }

    private func jsonData(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    private func requestBody() throws -> [String: Any] {
        let data = try #require(StubURLProtocol.lastRequestBody)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("工具仅在开启且当前提供商存在 Key 时可用")
    func availabilityRequiresEnabledAndKey() {
        for provider in WebSearchProvider.allCases {
            #expect(makeTool(provider: provider).isAvailable)
            #expect(!makeTool(provider: provider, enabled: false).isAvailable)
            #expect(!makeTool(provider: provider, apiKey: "  ").isAvailable)
        }
    }

    @Test("注册表动态隐藏不可用的联网搜索")
    func registryHidesUnavailableSearch() {
        let unavailable = ToolRegistry(tools: [makeTool(enabled: false)])
        #expect(unavailable.tools.isEmpty)
        #expect(unavailable.tool(named: "web_search") == nil)

        let available = ToolRegistry(tools: [makeTool()])
        #expect(available.tools.map(\.name) == ["web_search"])
        #expect(available.tool(named: "web_search") != nil)
    }

    @Test("Brave 使用查询参数和订阅令牌直连官方端点")
    func braveRequestFormat() async throws {
        resetStub(data: jsonData(["web": ["results": []]]))

        _ = try await makeTool(provider: .brave, apiKey: "brave-key").execute(
            arguments: [
                "query": "swift language",
                "country": "JP",
                "search_lang": "ja",
                "freshness": "pw",
                "count": 10,
            ],
            sshClient: MockSSHClient()
        )

        let request = try #require(StubURLProtocol.lastRequest)
        #expect(request.url?.host == "api.search.brave.com")
        #expect(request.url?.path == "/res/v1/web/search")
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "X-Subscription-Token") == "brave-key")
        #expect(!request.url!.absoluteString.contains("brave-key"))

        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let values = Dictionary(uniqueKeysWithValues: items.compactMap { item in
            item.value.map { (item.name, $0) }
        })
        #expect(values["q"] == "swift language")
        #expect(values["country"] == "JP")
        #expect(values["search_lang"] == "ja")
        #expect(values["freshness"] == "pw")
        #expect(values["count"] == "10")
    }

    @Test("Exa 使用 JSON 请求体和 x-api-key 直连官方端点")
    func exaRequestFormat() async throws {
        resetStub(data: jsonData(["results": []]))

        _ = try await makeTool(provider: .exa, apiKey: "exa-key").execute(
            arguments: ["query": "swift language", "country": "JP", "count": 8],
            sshClient: MockSSHClient()
        )

        let request = try #require(StubURLProtocol.lastRequest)
        let body = try requestBody()
        #expect(request.url?.absoluteString == "https://api.exa.ai/search")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "exa-key")
        #expect(body["query"] as? String == "swift language")
        #expect(body["numResults"] as? Int == 8)
        #expect(body["type"] as? String == "auto")
        #expect(body["userLocation"] as? String == "JP")
        #expect((body["contents"] as? [String: Any])?["highlights"] as? Bool == true)
        #expect(!String(data: try #require(StubURLProtocol.lastRequestBody), encoding: .utf8)!.contains("exa-key"))
    }

    @Test("AnySearch 使用 JSON 请求体和 Bearer Key 直连官方端点")
    func anySearchRequestFormat() async throws {
        resetStub(data: jsonData(["data": ["results": []]]))

        _ = try await makeTool(provider: .anySearch, apiKey: "anysearch-key").execute(
            arguments: [
                "query": "Swift 6 concurrency",
                "country": "CN",
                "search_lang": "zh-CN",
                "count": 6,
            ],
            sshClient: MockSSHClient()
        )

        let request = try #require(StubURLProtocol.lastRequest)
        let body = try requestBody()
        #expect(request.url?.absoluteString == "https://api.anysearch.com/v1/search")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer anysearch-key")
        #expect(body["query"] as? String == "Swift 6 concurrency")
        #expect(body["max_results"] as? Int == 6)
        #expect(body["zone"] as? String == "cn")
        #expect(body["language"] as? String == "zh-CN")
        #expect(body["format"] as? String == "json")
    }

    @Test("Tavily 使用基础搜索参数和 Bearer Key 直连官方端点")
    func tavilyRequestFormat() async throws {
        resetStub(data: jsonData(["results": []]))

        _ = try await makeTool(provider: .tavily, apiKey: "tavily-key").execute(
            arguments: [
                "query": "Swift 6 concurrency",
                "country": "JP",
                "freshness": "pw",
                "count": 7,
            ],
            sshClient: MockSSHClient()
        )

        let request = try #require(StubURLProtocol.lastRequest)
        let body = try requestBody()
        #expect(request.url?.absoluteString == "https://api.tavily.com/search")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tavily-key")
        #expect(body["query"] as? String == "Swift 6 concurrency")
        #expect(body["max_results"] as? Int == 7)
        #expect(body["search_depth"] as? String == "basic")
        #expect(body["include_answer"] as? Bool == false)
        #expect(body["include_raw_content"] as? Bool == false)
        #expect(body["country"] as? String == "japan")
        #expect(body["time_range"] as? String == "week")
        #expect(!String(data: try #require(StubURLProtocol.lastRequestBody), encoding: .utf8)!.contains("tavily-key"))
    }

    @Test("四种提供商响应统一格式化为可引用来源")
    func responseFormatting() async throws {
        let fixtures: [(WebSearchProvider, Data, [String])] = [
            (
                .brave,
                jsonData(["web": ["results": [[
                    "title": "Swift",
                    "url": "https://swift.org",
                    "description": "Swift language",
                    "age": "2 days ago",
                ]]]]),
                ["Swift", "https://swift.org", "Swift language", "2 days ago"]
            ),
            (
                .exa,
                jsonData(["results": [[
                    "title": "Exa result",
                    "url": "https://exa.example",
                    "publishedDate": "2026-08-01",
                    "highlights": ["Exa highlight"],
                ]]]),
                ["Exa result", "https://exa.example", "2026-08-01", "Exa highlight"]
            ),
            (
                .anySearch,
                jsonData(["data": ["results": [[
                    "title": "AnySearch result",
                    "url": "https://anysearch.example",
                    "snippet": "AnySearch snippet",
                ]]]]),
                ["AnySearch result", "https://anysearch.example", "AnySearch snippet"]
            ),
            (
                .tavily,
                jsonData(["results": [[
                    "title": "Tavily result",
                    "url": "https://tavily.example",
                    "content": "Tavily content",
                ]]]),
                ["Tavily result", "https://tavily.example", "Tavily content"]
            ),
        ]

        for (provider, data, expectedFragments) in fixtures {
            resetStub(data: data)
            let result = try await makeTool(provider: provider).execute(
                arguments: ["query": "swift"],
                sshClient: MockSSHClient()
            )
            #expect(result.isSuccess)
            for fragment in expectedFragments {
                #expect(result.output.contains(fragment))
            }
        }
    }

    @Test("API 错误标记提供商且不泄露 Key")
    func httpError() async throws {
        resetStub(data: Data("{\"message\":\"rate limited\"}".utf8), statusCode: 429)

        let result = try await makeTool(provider: .exa, apiKey: "secret-key").execute(
            arguments: ["query": "swift"],
            sshClient: MockSSHClient()
        )

        #expect(!result.isSuccess)
        #expect(result.output.contains("Exa"))
        #expect(result.output.contains("429"))
        #expect(result.output.contains("rate limited"))
        #expect(!result.output.contains("secret-key"))
    }

    @Test("查询不能为空且不得超过公共长度限制")
    func queryValidation() async {
        await #expect(throws: ToolError.self) {
            _ = try await makeTool().execute(arguments: [:], sshClient: MockSSHClient())
        }
        await #expect(throws: ToolError.self) {
            _ = try await makeTool().execute(arguments: ["query": "   "], sshClient: MockSSHClient())
        }
        await #expect(throws: ToolError.self) {
            _ = try await makeTool().execute(
                arguments: ["query": String(repeating: "x", count: 401)],
                sshClient: MockSSHClient()
            )
        }
    }
}
