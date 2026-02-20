/// 文件说明：KeychainServiceProtocol，定义凭据与密钥在安全存储中的读写契约。
import Foundation

/// KeychainServiceProtocol：
/// 抽象 Keychain 访问能力，统一管理服务器密码、SSH 私钥与私钥口令。
protocol KeychainServiceProtocol: Sendable {
    /// 保存服务器登录密码。
    /// - Parameters:
    ///   - password: 明文密码。
    ///   - serverID: 服务器标识。
    /// - Throws: 写入失败时抛出。
    func savePassword(_ password: String, forServer serverID: UUID) throws

    /// 读取服务器登录密码。
    /// - Parameter serverID: 服务器标识。
    /// - Returns: 密码；不存在时返回 `nil`。
    /// - Throws: 读取失败时抛出。
    func getPassword(forServer serverID: UUID) throws -> String?

    /// 删除服务器登录密码。
    /// - Parameter serverID: 服务器标识。
    /// - Throws: 删除失败时抛出。
    func deletePassword(forServer serverID: UUID) throws

    /// 保存 SSH 私钥数据。
    /// - Parameters:
    ///   - keyData: 私钥原始数据。
    ///   - keyID: 私钥标识。
    /// - Throws: 写入失败时抛出。
    func saveSSHKey(_ keyData: Data, withID keyID: String) throws

    /// 读取 SSH 私钥数据。
    /// - Parameter keyID: 私钥标识。
    /// - Returns: 私钥数据；不存在时返回 `nil`。
    /// - Throws: 读取失败时抛出。
    func getSSHKey(withID keyID: String) throws -> Data?

    /// 删除 SSH 私钥数据。
    /// - Parameter keyID: 私钥标识。
    /// - Throws: 删除失败时抛出。
    func deleteSSHKey(withID keyID: String) throws

    /// 保存私钥口令。
    /// - Parameters:
    ///   - passphrase: 私钥口令。
    ///   - keyID: 私钥标识。
    /// - Throws: 写入失败时抛出。
    func saveKeyPassphrase(_ passphrase: String, forKeyID keyID: String) throws

    /// 读取私钥口令。
    /// - Parameter keyID: 私钥标识。
    /// - Returns: 口令；不存在时返回 `nil`。
    /// - Throws: 读取失败时抛出。
    func getKeyPassphrase(forKeyID keyID: String) throws -> String?

    /// 删除私钥口令。
    /// - Parameter keyID: 私钥标识。
    /// - Throws: 删除失败时抛出。
    func deleteKeyPassphrase(forKeyID keyID: String) throws

    // MARK: - API Key

    /// 保存 AI 服务 API Key。
    /// - Parameter key: API Key 明文。
    /// - Throws: 写入失败时抛出。
    func saveAPIKey(_ key: String) throws

    /// 读取 AI 服务 API Key。
    /// - Returns: API Key；不存在时返回 `nil`。
    /// - Throws: 读取失败时抛出。
    func getAPIKey() throws -> String?

    /// 删除 AI 服务 API Key。
    /// - Throws: 删除失败时抛出。
    func deleteAPIKey() throws
}
