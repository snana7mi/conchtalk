/// 文件说明：PushRegistrationService，注册远程通知、上传/注销 APNs token，管理稳定 installID。
import Foundation
#if os(iOS)
import UIKit
#endif

/// PushUploading：PushAPIClient 的注册/注销子集，便于注入测试。
nonisolated protocol PushUploading: Sendable {
    func registerToken(apnsToken: String, environment: String, installID: String) async throws
    func deleteToken(installID: String) async throws
}
extension PushAPIClient: PushUploading {}

/// PushRegistrationService：拿到 APNs token → hex → 上传；持久化 installID。
@MainActor
final class PushRegistrationService {
    private let api: PushUploading
    private let defaults: UserDefaults
    let installID: String

    static var currentEnvironment: String {
        #if DEBUG
        return "sandbox"
        #else
        return "production"
        #endif
    }

    init(api: PushUploading, defaults: UserDefaults = .standard) {
        self.api = api
        self.defaults = defaults
        if let existing = defaults.string(forKey: "push.installID") {
            installID = existing
        } else {
            let id = UUID().uuidString
            defaults.set(id, forKey: "push.installID")
            installID = id
        }
    }

    /// 通知授权后调用：向系统注册远程通知（token 经 AppDelegate 回 handleToken）。
    func registerForRemoteNotifications() {
        #if os(iOS)
        UIApplication.shared.registerForRemoteNotifications()
        #endif
    }

    /// AppDelegate didRegister 回调 → 上传。
    func handleToken(_ deviceToken: Data) async throws {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        try await api.registerToken(apnsToken: hex, environment: Self.currentEnvironment, installID: installID)
    }

    /// 登出/关推送：注销。
    func unregister() async throws {
        try await api.deleteToken(installID: installID)
    }
}
