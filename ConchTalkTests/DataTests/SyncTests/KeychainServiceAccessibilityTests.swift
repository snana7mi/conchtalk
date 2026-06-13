/// 文件说明：KeychainServiceAccessibilityTests，验证凭据条目可访问性等级与存量迁移。
import Testing
@testable import ConchTalk
import Foundation
import Security

@Suite("KeychainService Accessibility", .serialized)
struct KeychainServiceAccessibilityTests {
    private let service = KeychainService()
    private let migratedFlagKey = "KeychainService.credentialAccessibilityMigrated"

    // MARK: - Helpers

    private func accessibility(forAccount account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let attrs = result as? [String: Any] else { return nil }
        return attrs[kSecAttrAccessible as String] as? String
    }

    private func addLegacyItem(account: String, value: String) throws {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                       kSecAttrAccount as String: account] as CFDictionary)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        try #require(status == errSecSuccess)
    }

    // MARK: - 用例

    @Test("savePassword 使用 AfterFirstUnlockThisDeviceOnly 等级")
    func savePassword_usesAfterFirstUnlockAccessibility() throws {
        let serverID = UUID()
        defer { try? service.deletePassword(forServer: serverID) }

        try service.savePassword("pw-123", forServer: serverID)

        let level = accessibility(forAccount: "com.cheung.ConchTalk.password.\(serverID.uuidString)")
        #expect(level == (kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String))
    }

    @Test("迁移把存量凭据条目更新为 AfterFirstUnlock 等级且值不变")
    func migrate_updatesLegacyCredentialItems() throws {
        let serverID = UUID()
        let keyID = UUID().uuidString
        let passwordAccount = "com.cheung.ConchTalk.password.\(serverID.uuidString)"
        let sshKeyAccount = "com.cheung.ConchTalk.sshkey.\(keyID)"
        UserDefaults.standard.removeObject(forKey: migratedFlagKey)
        defer {
            try? service.deletePassword(forServer: serverID)
            try? service.deleteSSHKey(withID: keyID)
            UserDefaults.standard.removeObject(forKey: migratedFlagKey)
        }
        try addLegacyItem(account: passwordAccount, value: "legacy-pw")
        try addLegacyItem(account: sshKeyAccount, value: "legacy-key")

        service.migrateCredentialAccessibilityIfNeeded()

        #expect(accessibility(forAccount: passwordAccount) == (kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String))
        #expect(accessibility(forAccount: sshKeyAccount) == (kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String))
        #expect(try service.getPassword(forServer: serverID) == "legacy-pw")
        #expect(try service.getSSHKey(withID: keyID) == Data("legacy-key".utf8))
    }

    @Test("迁移幂等：标记置位后第二次为 no-op")
    func migrate_isIdempotent() throws {
        let firstID = UUID()
        let secondID = UUID()
        let secondAccount = "com.cheung.ConchTalk.password.\(secondID.uuidString)"
        UserDefaults.standard.removeObject(forKey: migratedFlagKey)
        defer {
            try? service.deletePassword(forServer: firstID)
            try? service.deletePassword(forServer: secondID)
            UserDefaults.standard.removeObject(forKey: migratedFlagKey)
        }
        try addLegacyItem(account: "com.cheung.ConchTalk.password.\(firstID.uuidString)", value: "pw-1")

        service.migrateCredentialAccessibilityIfNeeded()
        #expect(UserDefaults.standard.bool(forKey: migratedFlagKey))

        try addLegacyItem(account: secondAccount, value: "pw-2")
        service.migrateCredentialAccessibilityIfNeeded()
        #expect(accessibility(forAccount: secondAccount) == (kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String))
    }

    @Test("迁移不触碰非凭据条目（auth token 维持原等级）")
    func migrate_doesNotTouchNonCredentialItems() throws {
        UserDefaults.standard.removeObject(forKey: migratedFlagKey)
        defer {
            try? service.deleteAccessToken()
            UserDefaults.standard.removeObject(forKey: migratedFlagKey)
        }
        try service.saveAccessToken("tok-123")

        service.migrateCredentialAccessibilityIfNeeded()

        #expect(accessibility(forAccount: "com.cheung.ConchTalk.auth.accessToken")
                == (kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String))
    }
}
