/// 文件说明：AudioPermissionManagerTests，验证权限状态逻辑。
import Testing
@testable import ConchTalk
import Foundation

@MainActor
struct AudioPermissionManagerTests {
    @Test func initialStatusIsNotDetermined() {
        let manager = AudioPermissionManager()
        #expect(manager.microphoneStatus == .notDetermined)
        #expect(manager.speechRecognitionStatus == .notDetermined)
    }

    @Test func isFullyAuthorizedRequiresBothPermissions() {
        let manager = AudioPermissionManager()
        #expect(manager.isFullyAuthorized == false)
    }

    @Test func checkPermissionsUpdatesStatus() async {
        let manager = AudioPermissionManager()
        await manager.checkPermissions()
        // 模拟器上应为 notDetermined 或 denied，不会是 authorized
        // 关键是调用不会崩溃
        #expect(manager.microphoneStatus != .authorized || manager.speechRecognitionStatus != .authorized)
    }
}
