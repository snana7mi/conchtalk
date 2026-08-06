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
    private var storedWebSearchAPIKeys: [WebSearchProvider: String] = [:]

    // MARK: - 错误注入

    var shouldThrow: Error?

    // 按 ID 定点注入：仅命中指定实体时抛错，其余正常。
    // 用于「第 N 个实体读取/写入失败」类用例（全方法注入 shouldThrow 无法表达）。
    var passwordReadErrors: [UUID: Error] = [:]
    var passwordWriteErrors: [UUID: Error] = [:]
    var sshKeyReadErrors: [String: Error] = [:]
    var sshKeyWriteErrors: [String: Error] = [:]

    // MARK: - Password

    func savePassword(_ password: String, forServer serverID: UUID) throws {
        if let error = shouldThrow { throw error }
        if let error = passwordWriteErrors[serverID] { throw error }
        passwords[serverID] = password
    }

    func getPassword(forServer serverID: UUID) throws -> String? {
        if let error = shouldThrow { throw error }
        if let error = passwordReadErrors[serverID] { throw error }
        return passwords[serverID]
    }

    func deletePassword(forServer serverID: UUID) throws {
        if let error = shouldThrow { throw error }
        passwords.removeValue(forKey: serverID)
    }

    // MARK: - SSH Key

    func saveSSHKey(_ keyData: Data, withID keyID: String) throws {
        if let error = shouldThrow { throw error }
        if let error = sshKeyWriteErrors[keyID] { throw error }
        sshKeys[keyID] = keyData
    }

    func getSSHKey(withID keyID: String) throws -> Data? {
        if let error = shouldThrow { throw error }
        if let error = sshKeyReadErrors[keyID] { throw error }
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

    // MARK: - Web Search API Key

    func saveWebSearchAPIKey(_ key: String, for provider: WebSearchProvider) throws {
        if let error = shouldThrow { throw error }
        storedWebSearchAPIKeys[provider] = key
    }

    func getWebSearchAPIKey(for provider: WebSearchProvider) throws -> String? {
        if let error = shouldThrow { throw error }
        return storedWebSearchAPIKeys[provider]
    }

    func deleteWebSearchAPIKey(for provider: WebSearchProvider) throws {
        if let error = shouldThrow { throw error }
        storedWebSearchAPIKeys.removeValue(forKey: provider)
    }

    // MARK: - 辅助方法

    func reset() {
        passwords = [:]
        sshKeys = [:]
        passphrases = [:]
        storedAPIKey = nil
        storedWebSearchAPIKeys = [:]
        shouldThrow = nil
        passwordReadErrors = [:]
        passwordWriteErrors = [:]
        sshKeyReadErrors = [:]
        sshKeyWriteErrors = [:]
    }
}
