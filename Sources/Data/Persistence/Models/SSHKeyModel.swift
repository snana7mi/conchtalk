/// 文件说明：SSHKeyModel，定义 SSH 密钥在 SwiftData 中的持久化结构。
import Foundation
import SwiftData

/// SSHKeyModel：
/// SSH 密钥持久化模型，维护密钥元数据以供本地存储与查询。
@Model
final class SSHKeyModel {
    @Attribute(.unique) var id: UUID
    var label: String
    var keyTypeRaw: String
    var fingerprint: String
    var publicKeyOpenSSH: String
    var sourceRaw: String
    var createdAt: Date

    // MARK: - 同步字段
    var syncVersion: Int64 = 0
    var modifiedAt: Date = Date()
    var isDeleted: Bool = false
    var isRemoteMerge: Bool = false

    /// 初始化 SSH 密钥持久化模型。
    /// - Parameters:
    ///   - id: 密钥标识。
    ///   - label: 展示标签。
    ///   - keyTypeRaw: 密钥类型原始值。
    ///   - fingerprint: 密钥指纹。
    ///   - publicKeyOpenSSH: OpenSSH 格式公钥。
    ///   - sourceRaw: 密钥来源原始值。
    ///   - createdAt: 创建时间。
    init(id: UUID = UUID(), label: String, keyTypeRaw: String, fingerprint: String, publicKeyOpenSSH: String, sourceRaw: String, createdAt: Date = Date()) {
        self.id = id
        self.label = label
        self.keyTypeRaw = keyTypeRaw
        self.fingerprint = fingerprint
        self.publicKeyOpenSSH = publicKeyOpenSSH
        self.sourceRaw = sourceRaw
        self.createdAt = createdAt
    }

    /// 转换为领域层 `SSHKey` 实体。
    /// - Returns: 对应的领域密钥对象。
    func toDomain() -> SSHKey {
        SSHKey(
            id: id,
            label: label,
            keyType: SSHKey.KeyType(rawValue: keyTypeRaw) ?? .unknown,
            fingerprint: fingerprint,
            publicKeyOpenSSH: publicKeyOpenSSH,
            createdAt: createdAt,
            source: SSHKey.KeySource(rawValue: sourceRaw) ?? .generated
        )
    }

    /// 从领域层 `SSHKey` 构建持久化模型。
    /// - Parameter key: 领域密钥对象。
    /// - Returns: 对应的持久化模型实例。
    static func fromDomain(_ key: SSHKey) -> SSHKeyModel {
        SSHKeyModel(
            id: key.id,
            label: key.label,
            keyTypeRaw: key.keyType.rawValue,
            fingerprint: key.fingerprint,
            publicKeyOpenSSH: key.publicKeyOpenSSH,
            sourceRaw: key.source.rawValue,
            createdAt: key.createdAt
        )
    }
}
