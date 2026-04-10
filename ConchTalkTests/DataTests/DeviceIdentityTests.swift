/// 文件说明：DeviceIdentityTests，验证跨平台设备标识的稳定性。
import Testing
@testable import ConchTalk

struct DeviceIdentityTests {
    @Test func deviceIdIsStable() {
        let id1 = DeviceIdentity.shortID
        let id2 = DeviceIdentity.shortID
        #expect(id1 == id2)
        #expect(id1.count == 8)
        #expect(id1.allSatisfy { $0.isHexDigit })
    }
}
