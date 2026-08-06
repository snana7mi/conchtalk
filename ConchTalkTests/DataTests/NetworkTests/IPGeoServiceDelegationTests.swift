/// 文件说明：IPGeoServiceDelegationTests，验证 IP 国家检测强制调用 Country 第三方 API。
import Testing
import Foundation
@testable import ConchTalk

/// IPGeoServiceDelegationTests：
/// 覆盖第三方请求格式、响应校验，以及私网地址不外发的安全边界。
@Suite("IPGeoService third-party API", .serialized)
struct IPGeoServiceDelegationTests {
    private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var responseData = Data()
        nonisolated(unsafe) static var responseStatusCode = 200
        nonisolated(unsafe) static var lastRequest: URLRequest?

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            Self.lastRequest = request
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

    private func resetStub(
        json: String = #"{"ip":"8.8.8.8","country":"US"}"#,
        statusCode: Int = 200
    ) {
        StubURLProtocol.responseData = Data(json.utf8)
        StubURLProtocol.responseStatusCode = statusCode
        StubURLProtocol.lastRequest = nil
    }

    @Test("私网和保留地址不发送第三方请求", arguments: [
        "10.0.0.5",         // 10/8 私网
        "172.16.0.1",       // 172.16/12 私网
        "192.168.1.1",      // 192.168/16 私网
        "127.0.0.1",        // 回环
        "169.254.169.254",  // 链路本地
        "0.0.0.1",          // 当前网络
        "100.64.0.1",       // CGNAT
        "224.0.0.1",        // 组播
        "240.0.0.1",        // 保留
        "::1",              // IPv6 回环
        "fc00::1",          // IPv6 ULA
    ])
    func privateAddressDoesNotCallAPI(ip: String) async {
        resetStub()

        let code = await IPGeoService.lookupCountryCode(for: ip, session: makeSession())

        #expect(code == nil)
        #expect(StubURLProtocol.lastRequest == nil)
    }

    @Test("公网 IP 只通过 api.country.is 查询国家代码")
    func publicIPAddressUsesCountryAPI() async throws {
        resetStub(json: #"{"ip":"8.8.8.8","country":"us"}"#)

        let code = await IPGeoService.lookupCountryCode(for: "8.8.8.8", session: makeSession())
        let request = try #require(StubURLProtocol.lastRequest)

        #expect(code == "US")
        #expect(request.url?.scheme == "https")
        #expect(request.url?.host == "api.country.is")
        #expect(request.url?.path == "/8.8.8.8")
        #expect(request.httpMethod == "GET")
    }

    @Test("公网 IPv6 作为路径参数调用同一第三方 API")
    func publicIPv6AddressUsesCountryAPI() async throws {
        resetStub(json: #"{"ip":"2001:4860:4860::8888","country":"US"}"#)

        let code = await IPGeoService.lookupCountryCode(
            for: "2001:4860:4860::8888",
            session: makeSession()
        )
        let request = try #require(StubURLProtocol.lastRequest)

        #expect(code == "US")
        #expect(request.url?.host == "api.country.is")
        #expect(request.url?.path == "/2001:4860:4860::8888")
    }

    @Test("第三方 API 非成功状态不提供本地回退")
    func APIErrorHasNoLocalFallback() async {
        resetStub(json: #"{"error":{"code":429,"message":"Rate limit exceeded"}}"#, statusCode: 429)

        let code = await IPGeoService.lookupCountryCode(for: "8.8.8.8", session: makeSession())

        #expect(code == nil)
        #expect(StubURLProtocol.lastRequest != nil)
    }

    @Test("无效国家代码被拒绝")
    func invalidCountryCodeIsRejected() async {
        resetStub(json: #"{"ip":"8.8.8.8","country":"United States"}"#)

        let code = await IPGeoService.lookupCountryCode(for: "8.8.8.8", session: makeSession())

        #expect(code == nil)
    }
}
