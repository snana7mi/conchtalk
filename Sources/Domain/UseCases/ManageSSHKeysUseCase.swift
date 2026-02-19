/// 文件说明：ManageSSHKeysUseCase，封装 SSH 密钥导入、查询与删除的业务流程。
import Foundation

/// ManageSSHKeysUseCase：
/// 负责将上层输入转换为可持久化的密钥数据，并通过 Keychain 服务完成安全存储操作。
final class ManageSSHKeysUseCase: @unchecked Sendable {
    private let keychainService: KeychainServiceProtocol

    /// 初始化 SSH 密钥管理用例。
    /// - Parameter keychainService: 密钥安全存储服务。
    init(keychainService: KeychainServiceProtocol) {
        self.keychainService = keychainService
    }

    /// 从文本导入 SSH 私钥并写入 Keychain。
    /// - Parameters:
    ///   - text: 私钥文本内容。
    ///   - keyID: 私钥标识。
    /// - Throws: 文本无法编码为 UTF-8 时抛出 `SSHKeyError.invalidKeyData`；
    ///   Keychain 写入失败时透传底层错误。
    /// - Side Effects: 向 Keychain 新增或覆盖对应 `keyID` 的私钥条目。
    func importKey(fromText text: String, withID keyID: String) throws {
        guard let data = text.data(using: .utf8) else {
            throw SSHKeyError.invalidKeyData
        }
        try keychainService.saveSSHKey(data, withID: keyID)
    }

    /// 从二进制数据导入 SSH 私钥并写入 Keychain。
    /// - Parameters:
    ///   - data: 私钥数据。
    ///   - keyID: 私钥标识。
    /// - Throws: Keychain 写入失败时抛出。
    /// - Side Effects: 向 Keychain 新增或覆盖对应 `keyID` 的私钥条目。
    func importKey(fromData data: Data, withID keyID: String) throws {
        try keychainService.saveSSHKey(data, withID: keyID)
    }

    /// 删除指定 SSH 私钥。
    /// - Parameter keyID: 私钥标识。
    /// - Throws: Keychain 删除失败时抛出。
    /// - Side Effects: 从 Keychain 移除对应 `keyID` 的私钥条目。
    func deleteKey(withID keyID: String) throws {
        try keychainService.deleteSSHKey(withID: keyID)
    }

    /// 获取指定 SSH 私钥数据。
    /// - Parameter keyID: 私钥标识。
    /// - Returns: 私钥数据；不存在时返回 `nil`。
    /// - Throws: Keychain 读取失败时抛出。
    func getKey(withID keyID: String) throws -> Data? {
        try keychainService.getSSHKey(withID: keyID)
    }
}

/// SSHKeyError：定义 SSH 密钥导入流程中可能出现的错误。
enum SSHKeyError: LocalizedError {
    case invalidKeyData
    case keyNotFound

    /// 面向 UI 的错误描述文案。
    var errorDescription: String? {
        switch self {
        case .invalidKeyData: return "Invalid SSH key data"
        case .keyNotFound: return "SSH key not found"
        }
    }
}
