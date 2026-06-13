/// 文件说明：IPGeoServiceDelegationTests，守护 IPGeoService 委托 PrivateNetworkGuard 后行为等价。
import Testing
import Foundation
@testable import ConchTalk

@Suite("IPGeoService delegation")
struct IPGeoServiceDelegationTests {

    @Test("私网/保留 IPv4 一律返回 nil（委托前后行为一致）", arguments: [
        "10.0.0.5",         // 10/8 私网
        "172.16.0.1",       // 172.16/12 私网
        "192.168.1.1",      // 192.168/16 私网
        "127.0.0.1",        // 回环
        "169.254.169.254",  // 链路本地
        "0.0.0.1",          // 当前网络
        "100.64.0.1",       // CGNAT
        "224.0.0.1",        // 组播
        "240.0.0.1",        // 保留
    ])
    func privateIPv4ReturnsNil(ip: String) {
        #expect(IPGeoService.lookupCountryCode(for: ip) == nil)
    }

    @Test("公网 IPv4 仍可查询到国家代码")
    func publicIPv4StillResolves() {
        // 测试宿主为 app（TEST_HOST），Bundle.main 含 dbip-country.mmdb
        #expect(IPGeoService.lookupCountryCode(for: "1.1.1.1") != nil)
    }
}
