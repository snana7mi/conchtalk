/// 文件说明：IPGeoService，通过 Country 第三方 API 查询公网 IP 所属国家代码。
import Foundation

/// IPGeoService：
/// 将服务器主机解析为公网 IPv4 / IPv6 地址后，强制调用 api.country.is 查询国家代码。
/// 不包含本地 IP 数据库，也不提供离线查询或本地回退。
nonisolated enum IPGeoService {
    private static let apiScheme = "https"
    private static let apiHost = "api.country.is"

    /// Country API 的最小响应结构，只读取国家代码，不请求更细粒度的位置数据。
    private struct CountryResponse: Decodable, Sendable {
        let country: String?
    }

    /// 查询服务器主机对应的国家代码。
    /// - Parameters:
    ///   - host: 服务器主机地址（IPv4、IPv6 或域名）。
    ///   - session: URLSession，允许测试注入隔离的网络传输。
    /// - Returns: 两位国家代码；私网、解析失败、API 失败或响应无效时返回 nil。
    static func lookupCountryCode(
        for host: String,
        session: URLSession = .shared
    ) async -> String? {
        // getaddrinfo 是同步阻塞调用，放到后台执行，避免冻结 MainActor。
        guard let ip = await Task.detached(priority: .utility, operation: {
            resolvePublicIPAddress(for: host)
        }).value,
              let url = lookupURL(for: ip) else {
            return nil
        }

        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 10
        )
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode),
                  let payload = try? JSONDecoder().decode(CountryResponse.self, from: data) else {
                return nil
            }
            return normalizedCountryCode(payload.country)
        } catch {
            return nil
        }
    }

    /// 构建固定第三方主机上的查询 URL，IP 仅作为路径参数。
    private static func lookupURL(for ip: String) -> URL? {
        var components = URLComponents()
        components.scheme = apiScheme
        components.host = apiHost
        components.path = "/\(ip)"
        return components.url
    }

    /// 将主机名或 IP 字面量解析为首个公网地址；混入非公网结果时按 fail-closed 跳过。
    private static func resolvePublicIPAddress(for rawHost: String) -> String? {
        var host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
        if host.hasPrefix("["), host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }
        guard !host.isEmpty else { return nil }

        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, nil, &hints, &result)
        defer { if result != nil { freeaddrinfo(result) } }
        guard status == 0, result != nil else { return nil }

        var firstPublicAddress: String?
        var info = result
        while let current = info {
            info = current.pointee.ai_next
            guard let address = current.pointee.ai_addr else { continue }

            switch Int32(address.pointee.sa_family) {
            case AF_INET:
                var ipv4 = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    $0.pointee.sin_addr
                }
                let bytes = withUnsafeBytes(of: ipv4) { Array($0) }
                guard PrivateNetworkGuard.isPublicIPv4Bytes(bytes) else { return nil }
                var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                guard inet_ntop(AF_INET, &ipv4, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else {
                    continue
                }
                firstPublicAddress = firstPublicAddress ?? String(cString: buffer)

            case AF_INET6:
                var ipv6 = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                    $0.pointee.sin6_addr
                }
                let bytes = withUnsafeBytes(of: ipv6) { Array($0) }
                guard PrivateNetworkGuard.isPublicIPv6Bytes(bytes) else { return nil }
                var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                guard inet_ntop(AF_INET6, &ipv6, &buffer, socklen_t(INET6_ADDRSTRLEN)) != nil else {
                    continue
                }
                firstPublicAddress = firstPublicAddress ?? String(cString: buffer)

            default:
                continue
            }
        }
        return firstPublicAddress
    }

    /// 只接受 ISO 3166-1 alpha-2 风格的 ASCII 国家代码。
    private static func normalizedCountryCode(_ rawCode: String?) -> String? {
        guard let code = rawCode?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased(),
              code.utf8.count == 2,
              code.utf8.allSatisfy({ $0 >= 65 && $0 <= 90 }) else {
            return nil
        }
        return code
    }
}
