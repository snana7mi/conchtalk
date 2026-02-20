/// 文件说明：KeychainService，实现凭据安全存储与读取能力。
import Foundation
import Security

/// KeychainService：提供基础设施层服务能力。
final class KeychainService: KeychainServiceProtocol, @unchecked Sendable {
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
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
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
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
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
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
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
