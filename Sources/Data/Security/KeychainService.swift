import Foundation
import Security

final class KeychainService: KeychainServiceProtocol, @unchecked Sendable {
    private let servicePrefix = "com.cheung.ConchTalk"

    // MARK: - Password

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
}

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
