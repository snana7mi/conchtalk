/// 文件说明：PrivateNetworkGuardTests，验证公网/非公网地址分类（SSRF 防护核心判定）。
/// 注意：Encoded & hostname suite 中依赖 DNS 的用例（localhost / example.com / .invalid）
/// 在离线环境可能 flaky——失败属环境问题，非实现回归。
import Testing
import Foundation
@testable import ConchTalk

@Suite("PrivateNetworkGuard")
struct PrivateNetworkGuardTests {

    @Suite("IPv4 classification")
    struct IPv4Tests {

        @Test("非公网 IPv4 判为 nonPublic", arguments: [
            "127.0.0.1",        // 回环
            "10.0.0.5",         // 10/8 私网
            "172.16.0.1",       // 172.16/12 私网下界
            "172.31.255.1",     // 172.16/12 私网上界
            "192.168.1.1",      // 192.168/16 私网
            "169.254.169.254",  // 链路本地（云 IMDS）
            "100.64.0.1",       // 100.64/10 CGNAT
            "0.0.0.0",          // 当前网络
            "224.0.0.1",        // 224/4 组播
            "240.0.0.1",        // 240/4 保留
        ])
        func nonPublicIPv4(host: String) {
            #expect(PrivateNetworkGuard.classify(host: host) == .nonPublic)
        }

        @Test("公网 IPv4 判为 publicHost", arguments: [
            "1.1.1.1",
            "93.184.216.34",
            "172.32.0.1",   // 紧邻 172.16/12 私网边界外
        ])
        func publicIPv4(host: String) {
            #expect(PrivateNetworkGuard.classify(host: host) == .publicHost)
        }
    }

    @Suite("IPv6 classification")
    struct IPv6Tests {

        @Test("非公网 IPv6 判为 nonPublic", arguments: [
            "::1",                  // 回环
            "::",                   // 未指定
            "fe80::1",              // fe80::/10 链路本地
            "fc00::1",              // fc00::/7 ULA
            "fd00::1",              // fc00::/7 ULA
            "ff02::1",              // ff00::/8 组播
            "::ffff:127.0.0.1",     // IPv4-mapped 回环
            "::ffff:192.168.0.1",   // IPv4-mapped 私网
        ])
        func nonPublicIPv6(host: String) {
            #expect(PrivateNetworkGuard.classify(host: host) == .nonPublic)
        }

        @Test("公网 IPv6 判为 publicHost", arguments: [
            "2606:4700:4700::1111",
            "2001:4860:4860::8888",
        ])
        func publicIPv6(host: String) {
            #expect(PrivateNetworkGuard.classify(host: host) == .publicHost)
        }
    }

    @Suite("Encoded & hostname")
    struct EncodedAndHostnameTests {

        // 注意：本 suite 依赖系统 resolver（getaddrinfo），属本地可跑的轻集成用例。

        @Test("decimal 编码 2130706433 解析后非公网（=127.0.0.1）")
        func decimalEncodedLoopback() {
            #expect(PrivateNetworkGuard.classify(host: "2130706433") == .nonPublic)
        }

        @Test("hex 编码 0x7f000001 解析后非公网（=127.0.0.1）")
        func hexEncodedLoopback() {
            // Darwin getaddrinfo 按 inet_aton 语义本地解析 0x 形式，行为确定（已在本机验证）
            #expect(PrivateNetworkGuard.classify(host: "0x7f000001") == .nonPublic)
        }

        @Test("localhost 解析后非公网")
        func localhostNonPublic() {
            #expect(PrivateNetworkGuard.classify(host: "localhost") == .nonPublic)
        }

        @Test("公网域名 example.com 解析后公网")
        func publicDomain() {
            #expect(PrivateNetworkGuard.classify(host: "example.com") == .publicHost)
        }

        @Test("无法解析的主机名判为 unresolvable")
        func unresolvableHost() {
            // .invalid 是 RFC 2606 保留 TLD，保证不可解析
            #expect(PrivateNetworkGuard.classify(host: "conchtalk-nonexistent.invalid") == .unresolvable)
        }
    }
}
