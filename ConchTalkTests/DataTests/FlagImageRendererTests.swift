/// 文件说明：FlagImageRendererTests，测试服务器默认头像与国旗渲染回归。
import Testing
import Foundation
import CoreGraphics
@testable import ConchTalk

@Suite("FlagImageRenderer")
struct FlagImageRendererTests {

    @Test("resolveServerIconData 在补充 countryCode 后改用国旗图标")
    func resolveServerIconDataSwitchesToFlagWhenCountryCodeArrives() {
        let serverID = UUID()
        let size: CGFloat = 80

        let initial = Server(
            id: serverID,
            name: "Tokyo",
            host: "203.0.113.10",
            username: "root",
            authMethod: .password,
            countryCode: nil
        )
        let updated = Server(
            id: serverID,
            name: "Tokyo",
            host: "203.0.113.10",
            username: "root",
            authMethod: .password,
            countryCode: "JP"
        )

        let initialIcon = FlagImageRenderer.resolveServerIconData(server: initial, size: size)
        let updatedIcon = FlagImageRenderer.resolveServerIconData(server: updated, size: size)
        let expectedFlag = FlagImageRenderer.renderFlag(countryCode: "JP", size: size)

        #expect(initialIcon != nil)
        #expect(updatedIcon == expectedFlag)
        #expect(updatedIcon != initialIcon)
    }
}
