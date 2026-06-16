/// 文件说明：AppDelegate，承接 APNs 远程通知注册回调（SwiftUI 无此 API，必须经 UIApplicationDelegate）。
#if os(iOS)
import UIKit

/// AppDelegate：把 device token / 注册失败转交 PushRegistrationService。
final class AppDelegate: NSObject, UIApplicationDelegate {
    /// 由 ConchTalkApp 在容器就绪后注入。
    @MainActor static var pushRegistration: PushRegistrationService?

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in
            try? await AppDelegate.pushRegistration?.handleToken(deviceToken)
        }
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("[Push] remote notification registration failed: \(error)")
    }
}
#endif
