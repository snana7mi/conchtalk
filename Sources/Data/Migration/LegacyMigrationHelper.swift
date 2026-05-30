import Foundation
import LLMGatewayKit
import Security

final class LegacyMigrationHelper {
    private enum LegacyDefaultsKeys {
        static let cachedAppleSub = "AuthService.cachedAppleSub"
        static let syncEnabled = "SyncState.enabled"
        static let lastPullTimestamp = "SyncState.lastPullTimestamp"
        static let disabledByUser = "SyncState.disabledByUserID"
    }

    private static let migrationFlag = "LLMGatewayKit.migrationDone_v1"

    private let defaults: UserDefaults
    private let legacyServicePrefix: String
    private let targetStore: TokenStoring

    init(
        defaults: UserDefaults = .standard,
        legacyServicePrefix: String = "com.cheung.ConchTalk",
        targetKeychainStore: TokenStoring = KeychainTokenStore()
    ) {
        self.defaults = defaults
        self.legacyServicePrefix = legacyServicePrefix
        self.targetStore = targetKeychainStore
    }

    func migrateIfNeeded() throws {
        guard !defaults.bool(forKey: Self.migrationFlag) else { return }

        if let sub = defaults.string(forKey: LegacyDefaultsKeys.cachedAppleSub) {
            defaults.set(sub, forKey: "LLMGatewayKit.cachedAppleSub")
        }
        if defaults.object(forKey: LegacyDefaultsKeys.syncEnabled) != nil {
            defaults.set(defaults.bool(forKey: LegacyDefaultsKeys.syncEnabled), forKey: "LLMGatewayKit.sync.isEnabled")
        }
        if let lastPull = defaults.string(forKey: LegacyDefaultsKeys.lastPullTimestamp) {
            defaults.set(lastPull, forKey: "LLMGatewayKit.sync.lastPullSince")
        }
        if let disabledBy = defaults.string(forKey: LegacyDefaultsKeys.disabledByUser) {
            defaults.set(disabledBy, forKey: "LLMGatewayKit.sync.disabledByUserID")
        }

        let legacyAccess = readKeychainString(account: "\(legacyServicePrefix).auth.accessToken")
        let legacyRefresh = readKeychainString(account: "\(legacyServicePrefix).auth.refreshToken")
        let legacyExpiryString = readKeychainString(account: "\(legacyServicePrefix).auth.tokenExpiry")
        if let access = legacyAccess, let refresh = legacyRefresh {
            // 旧 KeychainService.saveTokenExpiry 写入的是 String(date.timeIntervalSince1970)，
            // 不是 ISO8601；用 ISO8601 解析会永远失败、回退到 +15 分钟的错误过期时间。
            let expiry = legacyExpiryString
                .flatMap { Double($0) }
                .map { Date(timeIntervalSince1970: $0) }
                ?? Date().addingTimeInterval(15 * 60)
            try targetStore.save(accessToken: access, refreshToken: refresh, expiry: expiry)
        }

        defaults.set(true, forKey: Self.migrationFlag)
    }

    private func readKeychainString(account: String) -> String? {
        // 旧 KeychainService 的所有写入只设置了 kSecAttrAccount，从未设置 kSecAttrService。
        // 查询时若带上 kSecAttrService 会匹配不到任何旧项，导致令牌迁移恒失败。
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
