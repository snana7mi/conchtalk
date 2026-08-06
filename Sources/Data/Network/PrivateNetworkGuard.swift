/// 文件说明：PrivateNetworkGuard，判定主机是否为公网地址（SSRF 防护核心判定）。
import Foundation

/// PrivateNetworkGuard：
/// 提供 IPv4 / IPv6 公网字节判定与主机名分类，供 WebFetchTool（SSRF 执行前拦截）
/// 与 IPGeoService（私网地址跳过查询）复用同一份私网范围定义。
/// 判定 locus 说明：SSRF 的"内网"是远端服务器视角的内网（IMDS、其 localhost、所在 LAN），
/// 但回环/私网/链路本地等保留段是全网统一的，客户端按字节判定即可覆盖。
nonisolated enum PrivateNetworkGuard {

    /// 主机分类结果。
    enum HostClass: Equatable, Sendable {
        case publicHost     // 公网，可安全抓取
        case nonPublic      // 回环 / 私网 / 链路本地 / CGNAT / 组播等
        case unresolvable   // 无法解析（调用方按 fail-closed 拒绝）
    }

    /// 判定 host（IP 字面量或主机名）是否为公网。
    /// - IP 字面量：inet_pton 解析为字节后直接分类（天然处理去括号后的 IPv6，如 "::1"）。
    /// - 主机名 / 非点分编码（如十进制 2130706433、十六进制 0x7f000001）：
    ///   getaddrinfo(AF_UNSPEC) 解析全部 A/AAAA 记录，任一地址非公网即判非公网
    ///   （防"一个公网 + 一个内网"的混合记录绕过）。
    /// - 解析失败：unresolvable。
    static func classify(host: String) -> HostClass {
        // IPv4 字面量
        var v4 = in_addr()
        if inet_pton(AF_INET, host, &v4) == 1 {
            let bytes = withUnsafeBytes(of: v4) { Array($0) }
            return isPublicIPv4Bytes(bytes) ? .publicHost : .nonPublic
        }
        // IPv6 字面量（URL host 已去掉方括号）
        var v6 = in6_addr()
        if inet_pton(AF_INET6, host, &v6) == 1 {
            let bytes = withUnsafeBytes(of: v6) { Array($0) }
            return isPublicIPv6Bytes(bytes) ? .publicHost : .nonPublic
        }
        // 主机名 / 编码 IP：DNS 解析后逐地址判定
        return classifyByResolving(host)
    }

    /// IPv4 字节判定（4 字节，网络序；范围与 IPGeoService 既有逻辑一致）。
    static func isPublicIPv4Bytes(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 4 else { return false }
        let a = bytes[0], b = bytes[1]

        // 10.0.0.0/8 — 私网
        if a == 10 { return false }
        // 172.16.0.0/12 — 私网
        if a == 172 && (b >= 16 && b <= 31) { return false }
        // 192.168.0.0/16 — 私网
        if a == 192 && b == 168 { return false }
        // 127.0.0.0/8 — 回环
        if a == 127 { return false }
        // 169.254.0.0/16 — 链路本地（含云 IMDS 169.254.169.254）
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

    /// IPv6 字节判定（16 字节，网络序）。
    static func isPublicIPv6Bytes(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 16 else { return false }

        // ::ffff:0:0/96 — IPv4-mapped：抽取末 4 字节按 IPv4 判定
        if bytes[0...9].allSatisfy({ $0 == 0 }) && bytes[10] == 0xFF && bytes[11] == 0xFF {
            return isPublicIPv4Bytes(Array(bytes[12...15]))
        }
        // ::（未指定）与 ::1（回环）
        if bytes[0...14].allSatisfy({ $0 == 0 }) && (bytes[15] == 0 || bytes[15] == 1) {
            return false
        }
        // fe80::/10 — 链路本地
        if bytes[0] == 0xFE && (bytes[1] & 0xC0) == 0x80 { return false }
        // fc00::/7 — ULA
        if (bytes[0] & 0xFE) == 0xFC { return false }
        // ff00::/8 — 组播
        if bytes[0] == 0xFF { return false }

        // 其余（含 2000::/3 全局单播）按公网处理
        return true
    }

    // MARK: - DNS Resolution

    /// 通过 getaddrinfo(AF_UNSPEC) 解析主机名并逐地址分类。
    private static func classifyByResolving(_ host: String) -> HostClass {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC // 同时解析 A 与 AAAA
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, nil, &hints, &result)
        defer { if result != nil { freeaddrinfo(result) } }
        guard status == 0, result != nil else { return .unresolvable }

        var sawAddress = false
        var info = result
        while let current = info {
            // defer 保证 continue 时也推进链表，避免死循环
            defer { info = current.pointee.ai_next }
            guard let addr = current.pointee.ai_addr else { continue }
            switch Int32(addr.pointee.sa_family) {
            case AF_INET:
                sawAddress = true
                let v4 = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                let bytes = withUnsafeBytes(of: v4) { Array($0) }
                if !isPublicIPv4Bytes(bytes) { return .nonPublic }
            case AF_INET6:
                sawAddress = true
                let v6 = addr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
                let bytes = withUnsafeBytes(of: v6) { Array($0) }
                if !isPublicIPv6Bytes(bytes) { return .nonPublic }
            default:
                continue
            }
        }
        // 解析成功但没有任何 A/AAAA 地址 -> 按 fail-closed 处理
        return sawAddress ? .publicHost : .unresolvable
    }
}
