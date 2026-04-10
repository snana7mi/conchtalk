/// 文件说明：KeychainServiceProtocol，定义凭据与密钥在安全存储中的读写契约。
import Foundation

/// KeychainServiceProtocol：
/// 抽象 Keychain 访问能力，统一管理服务器密码、SSH 私钥与私钥口令。
nonisolated protocol KeychainServiceProtocol: Sendable {
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

    // MARK: - Auth Tokens

    /// 保存认证访问令牌。
    /// - Parameter token: 访问令牌字符串。
    /// - Throws: 写入失败时抛出。
    func saveAccessToken(_ token: String) throws

    /// 读取认证访问令牌。
    /// - Returns: 访问令牌；不存在时返回 `nil`。
    /// - Throws: 读取失败时抛出。
    func getAccessToken() throws -> String?

    /// 删除认证访问令牌。
    /// - Throws: 删除失败时抛出。
    func deleteAccessToken() throws

    /// 保存刷新令牌。
    /// - Parameter token: 刷新令牌字符串。
    /// - Throws: 写入失败时抛出。
    func saveRefreshToken(_ token: String) throws

    /// 读取刷新令牌。
    /// - Returns: 刷新令牌；不存在时返回 `nil`。
    /// - Throws: 读取失败时抛出。
    func getRefreshToken() throws -> String?

    /// 删除刷新令牌。
    /// - Throws: 删除失败时抛出。
    func deleteRefreshToken() throws

    /// 保存令牌过期时间。
    /// - Parameter date: 过期时间。
    /// - Throws: 写入失败时抛出。
    func saveTokenExpiry(_ date: Date) throws

    /// 读取令牌过期时间。
    /// - Returns: 过期时间；不存在时返回 `nil`。
    /// - Throws: 读取失败时抛出。
    func getTokenExpiry() throws -> Date?

    /// 删除令牌过期时间。
    /// - Throws: 删除失败时抛出。
    func deleteTokenExpiry() throws

    /// 删除所有认证令牌（访问令牌、刷新令牌、过期时间）。
    /// - Throws: 删除失败时抛出。
    func deleteAllAuthTokens() throws
}
