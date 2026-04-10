/// 文件说明：IPGeoService，通过本地离线 MMDB 数据库查询 IP 所属国家代码。
import Foundation

/// IPGeoService：
/// 使用 Bundle 内嵌的 GeoLite2-Country.mmdb 离线查询，不发送任何网络请求。
/// 仅查询公网 IP，私网/保留地址直接跳过。
nonisolated enum IPGeoService {

    private static let reader: MMDBReader? = {
        guard let url = Bundle.main.url(forResource: "dbip-country", withExtension: "mmdb") else { return nil }
        return MMDBReader(url: url)
    }()

    /// 查询 IP 地址对应的国家代码。
    /// - Parameter host: 服务器主机地址（IPv4 地址或域名）。
    /// - Returns: 两位国家代码（如 "US"、"JP"），私网地址或查询失败返回 nil。
    static func lookupCountryCode(for host: String) -> String? {
        // 先尝试 DNS 解析域名到 IP
        let ip = resolveToIPv4(host) ?? host

        // 私网/保留地址不查询
        guard isPublicIPv4(ip) else { return nil }

        return reader?.countryCode(for: ip)
    }

    // MARK: - Private IP Detection

    /// 判断是否为公网 IPv4 地址。
    private static func isPublicIPv4(_ ip: String) -> Bool {
        let parts = ip.split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 4 else { return false }

        let a = parts[0], b = parts[1]

        // 10.0.0.0/8 — 私网
        if a == 10 { return false }
        // 172.16.0.0/12 — 私网
        if a == 172 && (b >= 16 && b <= 31) { return false }
        // 192.168.0.0/16 — 私网
        if a == 192 && b == 168 { return false }
        // 127.0.0.0/8 — 回环
        if a == 127 { return false }
        // 169.254.0.0/16 — 链路本地
        if a == 169 && b == 254 { return false }
        // 0.0.0.0/8 — 当前网络
        if a == 0 { return false }
        // 100.64.0.0/10 — CGNAT
        if a == 100 && (b >= 64 && b <= 127) { return false }
        // 224.0.0.0/4 — 组播
        if a >= 224 && a <= 239 { return false }
        // 240.0.0.0/4 — 保留
        if a >= 240 { return false }

        return true
    }

    /// 将域名解析为 IPv4 地址。
    private static func resolveToIPv4(_ host: String) -> String? {
        // 如果已经是 IPv4 格式，直接返回
        let parts = host.split(separator: ".")
        if parts.count == 4 && parts.allSatisfy({ UInt8($0) != nil }) {
            return nil // 已经是 IP，无需解析
        }

        // DNS 解析
        var hints = addrinfo()
        hints.ai_family = AF_INET // 仅 IPv4
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, nil, &hints, &result)
        defer { if result != nil { freeaddrinfo(result) } }
        guard status == 0, let info = result else { return nil }

        var addr = info.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &addr.sin_addr, &buf, socklen_t(INET_ADDRSTRLEN))
        return String(cString: buf)
    }
}
