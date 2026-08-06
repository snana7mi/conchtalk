/// 文件说明：KeychainServiceAccessibilityTests，验证本机凭据条目可访问性等级与存量迁移。
import Testing
@testable import ConchTalk
import Foundation
import Security

@Suite("KeychainService Accessibility", .serialized)
struct KeychainServiceAccessibilityTests {
    private let service = KeychainService()
    private let migratedFlagKey = "KeychainService.credentialAccessibilityMigrated"

    private func accessibility(forAccount account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let attributes = result as? [String: Any] else { return nil }
        return attributes[kSecAttrAccessible as String] as? String
    }

    private func addLegacyItem(account: String, value: String) throws {
        removeItem(account: account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        try #require(SecItemAdd(query as CFDictionary, nil) == errSecSuccess)
    }

    private func removeItem(account: String) {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
        ] as CFDictionary)
    }

    @Test("savePassword 使用 AfterFirstUnlockThisDeviceOnly 等级")
    func savePasswordUsesAfterFirstUnlockAccessibility() throws {
        let serverID = UUID()
        defer { try? service.deletePassword(forServer: serverID) }

        try service.savePassword("pw-123", forServer: serverID)

        let level = accessibility(forAccount: "com.cheung.ConchTalk.password.\(serverID.uuidString)")
        #expect(level == (kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String))
    }

    @Test("联网搜索 API Key 使用仅本机解锁可读等级")
    func webSearchKeyUsesWhenUnlockedAccessibility() throws {
        let account = "com.cheung.ConchTalk.braveSearch.apikey"
        defer { try? service.deleteWebSearchAPIKey(for: .brave) }

        try service.saveWebSearchAPIKey("brave-key", for: .brave)

        #expect(try service.getWebSearchAPIKey(for: .brave) == "brave-key")
        #expect(accessibility(forAccount: account) == (kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String))
    }

    @Test("迁移把存量本机凭据更新为 AfterFirstUnlock 且值不变")
    func migrateUpdatesLegacyCredentialItems() throws {
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
}
