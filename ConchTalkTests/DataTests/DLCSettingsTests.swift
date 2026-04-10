/// 文件说明：DLCSettingsTests，测试 DLC 设置的读写与逻辑。
import Foundation
import Testing
@testable import ConchTalk

@Suite("DLCSettings")
struct DLCSettingsTests {

    init() {
        DLCSettings.isGlobalEnabled = false
        DLCSettings.clearAllServerOverrides()
    }

    @Test("全局开关默认关闭")
    func globalDefaultOff() {
        #expect(DLCSettings.isGlobalEnabled == false)
    }

    @Test("全局开关读写")
    func globalToggle() {
        DLCSettings.isGlobalEnabled = true
        #expect(DLCSettings.isGlobalEnabled == true)
        DLCSettings.isGlobalEnabled = false
        #expect(DLCSettings.isGlobalEnabled == false)
    }

    @Test("单服务器 override 默认跟随全局")
    func serverDefaultFollowsGlobal() {
        let serverID = UUID()
        #expect(DLCSettings.serverOverride(for: serverID) == nil)
        #expect(DLCSettings.isEffectivelyEnabled(for: serverID) == false)

        DLCSettings.isGlobalEnabled = true
        #expect(DLCSettings.isEffectivelyEnabled(for: serverID) == true)
    }

    @Test("单服务器显式开启覆盖全局关闭")
    func serverOverrideOn() {
        let serverID = UUID()
        DLCSettings.isGlobalEnabled = false
        DLCSettings.setServerOverride(for: serverID, enabled: true)
        #expect(DLCSettings.isEffectivelyEnabled(for: serverID) == true)
    }

    @Test("单服务器显式关闭覆盖全局开启")
    func serverOverrideOff() {
        let serverID = UUID()
        DLCSettings.isGlobalEnabled = true
        DLCSettings.setServerOverride(for: serverID, enabled: false)
        #expect(DLCSettings.isEffectivelyEnabled(for: serverID) == false)
    }

    @Test("前置条件：全部满足返回 nil")
    func prerequisiteAllMet() {
        let result = DLCSettings.checkPrerequisites(isLoggedIn: true, isPaid: true, isSyncEnabled: true)
        #expect(result == nil)
    }

    @Test("前置条件：云同步未开返回错误")
    func prerequisiteSyncDisabled() {
        let result = DLCSettings.checkPrerequisites(isLoggedIn: true, isPaid: true, isSyncEnabled: false)
        #expect(result != nil)
    }
}
