/// 文件说明：SSHKey，定义 SSH 密钥的领域实体模型。
import Foundation

/// SSHKey：
/// 表示一个 SSH 密钥的核心信息，包括标签、类型、指纹、公钥及来源。
struct SSHKey: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var label: String
    var keyType: KeyType
    var fingerprint: String        // "SHA256:xxxx"
    var publicKeyOpenSSH: String   // "ssh-ed25519 AAAA..." for copy
    var createdAt: Date
    var source: KeySource

    /// KeyType：定义 SSH 密钥算法类型。
    enum KeyType: String, Codable, Hashable, Sendable, CaseIterable {
        case ed25519
        case rsa4096
        case ecdsaP256
        case unknown  // for migrated keys where type detection failed

        var displayName: String {
            switch self {
            case .ed25519: "Ed25519"
            case .rsa4096: "RSA 4096"
            case .ecdsaP256: "ECDSA P-256"
            case .unknown: "Unknown"
            }
        }
    }

    /// KeySource：定义密钥来源方式。
    enum KeySource: String, Codable, Hashable, Sendable {
        case generated
        case imported
    }

    /// 初始化 SSH 密钥实体。
    /// - Parameters:
    ///   - id: 密钥标识。
    ///   - label: 展示标签。
    ///   - keyType: 密钥算法类型。
    ///   - fingerprint: 密钥指纹（SHA256 格式）。
    ///   - publicKeyOpenSSH: OpenSSH 格式公钥字符串。
    ///   - createdAt: 创建时间。
    ///   - source: 密钥来源（生成或导入）。
    init(id: UUID = UUID(), label: String, keyType: KeyType, fingerprint: String = "", publicKeyOpenSSH: String = "", createdAt: Date = Date(), source: KeySource) {
        self.id = id
        self.label = label
        self.keyType = keyType
        self.fingerprint = fingerprint
        self.publicKeyOpenSSH = publicKeyOpenSSH
        self.createdAt = createdAt
        self.source = source
    }
}
