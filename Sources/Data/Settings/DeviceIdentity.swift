/// 文件说明：DeviceIdentity，提供跨平台持久设备标识。
import Foundation
import UIKit

/// DeviceIdentity：
/// 优先使用 identifierForVendor，缺失时回退到 Keychain 持久化 UUID。
nonisolated enum DeviceIdentity {
    /// 设备 UUID 的前 8 位十六进制。
    static let shortID: String = {
        let full = fullID
        return String(full.uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
    }()

    private static let fullID: UUID = {
        // identifierForVendor 是 MainActor 隔离的，使用 assumeIsolated 安全访问（静态初始化在主线程执行）
        let vendorID = MainActor.assumeIsolated {
            UIDevice.current.identifierForVendor
        }
        return vendorID ?? loadOrCreateKeychainUUID()
    }()

    private static let keychainKey = "com.cheung.ConchTalk.deviceID"

    private static func loadOrCreateKeychainUUID() -> UUID {
        // 从 Keychain 读取
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: keychainKey,
            kSecReturnData as String: true
        ]
        var result: AnyObject?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
           let data = result as? Data,
           let str = String(data: data, encoding: .utf8),
           let uuid = UUID(uuidString: str) {
            return uuid
        }
        // 创建新的 UUID 并存入 Keychain
        let newID = UUID()
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: keychainKey,
            kSecValueData as String: newID.uuidString.data(using: .utf8)!
        ]
        SecItemAdd(addQuery as CFDictionary, nil)
        return newID
    }
}
