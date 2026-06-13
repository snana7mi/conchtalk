/// 文件说明：KeychainService，实现凭据安全存储与读取能力。
import Foundation
import Security

/// KeychainService：提供基础设施层服务能力。
nonisolated final class KeychainService: KeychainServiceProtocol, @unchecked Sendable {
    private let servicePrefix = "com.cheung.ConchTalk"

    // MARK: - Password

    /// savePassword：保存当前数据变更到持久层。
    func savePassword(_ password: String, forServer serverID: UUID) throws {
        guard let data = password.data(using: .utf8) else { throw KeychainError.encodingFailed }

        let key = "\(servicePrefix).password.\(serverID.uuidString)"

        // Delete existing
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
    }

    /// getPassword：获取当前所需的信息或对象。
    func getPassword(forServer serverID: UUID) throws -> String? {
        let key = "\(servicePrefix).password.\(serverID.uuidString)"

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainError.readFailed(status)
        }

        return String(data: data, encoding: .utf8)
    }

    /// deletePassword：删除目标数据并维护一致性。
    func deletePassword(forServer serverID: UUID) throws {
        let key = "\(servicePrefix).password.\(serverID.uuidString)"

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed(status)
        }
    }

    // MARK: - SSH Keys

    /// saveSSHKey：保存当前数据变更到持久层。
    func saveSSHKey(_ keyData: Data, withID keyID: String) throws {
        let key = "\(servicePrefix).sshkey.\(keyID)"

        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecValueData as String: keyData,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
    }

    /// getSSHKey：获取当前所需的信息或对象。
    func getSSHKey(withID keyID: String) throws -> Data? {
        let key = "\(servicePrefix).sshkey.\(keyID)"

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainError.readFailed(status)
        }

        return data
    }

    /// deleteSSHKey：删除目标数据并维护一致性。
    func deleteSSHKey(withID keyID: String) throws {
        let key = "\(servicePrefix).sshkey.\(keyID)"

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed(status)
        }
    }

    // MARK: - SSH Key Passphrase

    /// saveKeyPassphrase：保存当前数据变更到持久层。
    func saveKeyPassphrase(_ passphrase: String, forKeyID keyID: String) throws {
        guard let data = passphrase.data(using: .utf8) else { throw KeychainError.encodingFailed }

        let key = "\(servicePrefix).sshkey.passphrase.\(keyID)"

        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
    }

    /// getKeyPassphrase：获取当前所需的信息或对象。
    func getKeyPassphrase(forKeyID keyID: String) throws -> String? {
        let key = "\(servicePrefix).sshkey.passphrase.\(keyID)"

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainError.readFailed(status)
        }

        return String(data: data, encoding: .utf8)
    }

    /// deleteKeyPassphrase：删除目标数据并维护一致性。
    func deleteKeyPassphrase(forKeyID keyID: String) throws {
        let key = "\(servicePrefix).sshkey.passphrase.\(keyID)"

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed(status)
        }
    }

    // MARK: - API Key

    /// saveAPIKey：将 AI 服务 API Key 安全存储到 Keychain。
    func saveAPIKey(_ key: String) throws {
        guard let data = key.data(using: .utf8) else { throw KeychainError.encodingFailed }

        let account = "\(servicePrefix).apikey"

        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
    }

    /// getAPIKey：从 Keychain 读取 AI 服务 API Key。
    func getAPIKey() throws -> String? {
        let account = "\(servicePrefix).apikey"

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainError.readFailed(status)
        }

        return String(data: data, encoding: .utf8)
    }

    /// deleteAPIKey：从 Keychain 删除 AI 服务 API Key。
    func deleteAPIKey() throws {
        let account = "\(servicePrefix).apikey"

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed(status)
        }
    }

    // MARK: - Auth Access Token

    /// saveAccessToken：将认证访问令牌安全存储到 Keychain。
    func saveAccessToken(_ token: String) throws {
        guard let data = token.data(using: .utf8) else { throw KeychainError.encodingFailed }

        let account = "\(servicePrefix).auth.accessToken"

        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
    }

    /// getAccessToken：从 Keychain 读取认证访问令牌。
    func getAccessToken() throws -> String? {
        let account = "\(servicePrefix).auth.accessToken"

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainError.readFailed(status)
        }

        return String(data: data, encoding: .utf8)
    }

    /// deleteAccessToken：从 Keychain 删除认证访问令牌。
    func deleteAccessToken() throws {
        let account = "\(servicePrefix).auth.accessToken"

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed(status)
        }
    }

    // MARK: - Auth Refresh Token

    /// saveRefreshToken：将刷新令牌安全存储到 Keychain。
    func saveRefreshToken(_ token: String) throws {
        guard let data = token.data(using: .utf8) else { throw KeychainError.encodingFailed }

        let account = "\(servicePrefix).auth.refreshToken"

        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
    }

    /// getRefreshToken：从 Keychain 读取刷新令牌。
    func getRefreshToken() throws -> String? {
        let account = "\(servicePrefix).auth.refreshToken"

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainError.readFailed(status)
        }

        return String(data: data, encoding: .utf8)
    }

    /// deleteRefreshToken：从 Keychain 删除刷新令牌。
    func deleteRefreshToken() throws {
        let account = "\(servicePrefix).auth.refreshToken"

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed(status)
        }
    }

    // MARK: - Auth Token Expiry

    /// saveTokenExpiry：将令牌过期时间安全存储到 Keychain。
    func saveTokenExpiry(_ date: Date) throws {
        let timeInterval = String(date.timeIntervalSince1970)
        guard let data = timeInterval.data(using: .utf8) else { throw KeychainError.encodingFailed }

        let account = "\(servicePrefix).auth.tokenExpiry"

        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
    }

    /// getTokenExpiry：从 Keychain 读取令牌过期时间。
    func getTokenExpiry() throws -> Date? {
        let account = "\(servicePrefix).auth.tokenExpiry"

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainError.readFailed(status)
        }

        guard let string = String(data: data, encoding: .utf8),
              let timeInterval = Double(string) else {
            return nil
        }

        return Date(timeIntervalSince1970: timeInterval)
    }

    /// deleteTokenExpiry：从 Keychain 删除令牌过期时间。
    func deleteTokenExpiry() throws {
        let account = "\(servicePrefix).auth.tokenExpiry"

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed(status)
        }
    }

    // MARK: - Delete All Auth Tokens

    /// deleteAllAuthTokens：一次性删除所有认证令牌。
    func deleteAllAuthTokens() throws {
        try deleteAccessToken()
        try deleteRefreshToken()
        try deleteTokenExpiry()
    }

    // MARK: - 存量迁移

    /// 将存量凭据条目（password / sshkey / sshkey.passphrase）的 accessibility
    /// 迁移为 AfterFirstUnlockThisDeviceOnly。幂等：全部成功后置位标记，之后不再执行。
    /// 必须在前台（设备解锁）调用：SecItemUpdate 变更 accessibility 需要重新加密条目数据。
    func migrateCredentialAccessibilityIfNeeded() {
        let migratedKey = "KeychainService.credentialAccessibilityMigrated"
        guard !UserDefaults.standard.bool(forKey: migratedKey) else { return }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            UserDefaults.standard.set(true, forKey: migratedKey)
            return
        }
        guard status == errSecSuccess, let items = result as? [[String: Any]] else { return }

        // ".sshkey." 前缀同时覆盖 ".sshkey.passphrase." 条目
        let credentialPrefixes = ["\(servicePrefix).password.", "\(servicePrefix).sshkey."]
        var allSucceeded = true
        for item in items {
            guard let account = item[kSecAttrAccount as String] as? String,
                  credentialPrefixes.contains(where: { account.hasPrefix($0) }) else { continue }
            let updateQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrAccount as String: account,
            ]
            let attributes: [String: Any] = [
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ]
            let updateStatus = SecItemUpdate(updateQuery as CFDictionary, attributes as CFDictionary)
            if updateStatus != errSecSuccess && updateStatus != errSecItemNotFound {
                allSucceeded = false
            }
        }
        if allSucceeded {
            UserDefaults.standard.set(true, forKey: migratedKey)
        }
    }
}

/// KeychainError：定义钥匙串读写过程中的错误类型。
enum KeychainError: LocalizedError {
    case saveFailed(OSStatus)
    case readFailed(OSStatus)
    case deleteFailed(OSStatus)
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .saveFailed(let s): return "Keychain save failed (status: \(s))"
        case .readFailed(let s): return "Keychain read failed (status: \(s))"
        case .deleteFailed(let s): return "Keychain delete failed (status: \(s))"
        case .encodingFailed: return "Failed to encode data"
        }
    }
}
