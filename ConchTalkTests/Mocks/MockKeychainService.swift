/// 文件说明：MockKeychainService，测试用 Keychain 服务模拟，内存字典存储与错误注入。
@testable import ConchTalk
import Foundation

/// MockKeychainService：
/// 实现 KeychainServiceProtocol 的测试替身，使用内存字典替代真实 Keychain。
final class MockKeychainService: KeychainServiceProtocol, @unchecked Sendable {

    // MARK: - 内存存储

    private var passwords: [UUID: String] = [:]
    private var sshKeys: [String: Data] = [:]
    private var passphrases: [String: String] = [:]
    private var storedAPIKey: String?
    private var storedAccessToken: String?
    private var storedRefreshToken: String?
    private var storedTokenExpiry: Date?

    // MARK: - 错误注入

    var shouldThrow: Error?

    // MARK: - Password

    func savePassword(_ password: String, forServer serverID: UUID) throws {
        if let error = shouldThrow { throw error }
        passwords[serverID] = password
    }

    func getPassword(forServer serverID: UUID) throws -> String? {
        if let error = shouldThrow { throw error }
        return passwords[serverID]
    }

    func deletePassword(forServer serverID: UUID) throws {
        if let error = shouldThrow { throw error }
        passwords.removeValue(forKey: serverID)
    }

    // MARK: - SSH Key

    func saveSSHKey(_ keyData: Data, withID keyID: String) throws {
        if let error = shouldThrow { throw error }
        sshKeys[keyID] = keyData
    }

    func getSSHKey(withID keyID: String) throws -> Data? {
        if let error = shouldThrow { throw error }
        return sshKeys[keyID]
    }

    func deleteSSHKey(withID keyID: String) throws {
        if let error = shouldThrow { throw error }
        sshKeys.removeValue(forKey: keyID)
    }

    // MARK: - Key Passphrase

    func saveKeyPassphrase(_ passphrase: String, forKeyID keyID: String) throws {
        if let error = shouldThrow { throw error }
        passphrases[keyID] = passphrase
    }

    func getKeyPassphrase(forKeyID keyID: String) throws -> String? {
        if let error = shouldThrow { throw error }
        return passphrases[keyID]
    }

    func deleteKeyPassphrase(forKeyID keyID: String) throws {
        if let error = shouldThrow { throw error }
        passphrases.removeValue(forKey: keyID)
    }

    // MARK: - API Key

    func saveAPIKey(_ key: String) throws {
        if let error = shouldThrow { throw error }
        storedAPIKey = key
    }

    func getAPIKey() throws -> String? {
        if let error = shouldThrow { throw error }
        return storedAPIKey
    }

    func deleteAPIKey() throws {
        if let error = shouldThrow { throw error }
        storedAPIKey = nil
    }

    // MARK: - Auth Tokens

    func saveAccessToken(_ token: String) throws {
        if let error = shouldThrow { throw error }
        storedAccessToken = token
    }

    func getAccessToken() throws -> String? {
        if let error = shouldThrow { throw error }
        return storedAccessToken
    }

    func deleteAccessToken() throws {
        if let error = shouldThrow { throw error }
        storedAccessToken = nil
    }

    func saveRefreshToken(_ token: String) throws {
        if let error = shouldThrow { throw error }
        storedRefreshToken = token
    }

    func getRefreshToken() throws -> String? {
        if let error = shouldThrow { throw error }
        return storedRefreshToken
    }

    func deleteRefreshToken() throws {
        if let error = shouldThrow { throw error }
        storedRefreshToken = nil
    }

    func saveTokenExpiry(_ date: Date) throws {
        if let error = shouldThrow { throw error }
        storedTokenExpiry = date
    }

    func getTokenExpiry() throws -> Date? {
        if let error = shouldThrow { throw error }
        return storedTokenExpiry
    }

    func deleteTokenExpiry() throws {
        if let error = shouldThrow { throw error }
        storedTokenExpiry = nil
    }

    func deleteAllAuthTokens() throws {
        if let error = shouldThrow { throw error }
        storedAccessToken = nil
        storedRefreshToken = nil
        storedTokenExpiry = nil
    }

    // MARK: - 辅助方法

    func reset() {
        passwords = [:]
        sshKeys = [:]
        passphrases = [:]
        storedAPIKey = nil
        storedAccessToken = nil
        storedRefreshToken = nil
        storedTokenExpiry = nil
        shouldThrow = nil
    }
}
