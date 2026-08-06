// Server connection info - NOT a SwiftData model, just a value type used at the domain level
/// 文件说明：Server，定义远端服务器连接配置的领域实体模型。
import Foundation

/// Server：
/// 表示一台可连接服务器的核心信息，包括地址、认证方式、分组及最近连接时间。
nonisolated struct Server: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var name: String
    var host: String
    var port: Int
    var username: String
    var authMethod: AuthMethod
    var groupID: UUID?
    var countryCode: String?
    var iconData: Data?
    var lastConnectedAt: Date?
    var permissionLevel: ServerPermissionLevel
    // 服务器有效期，nil 表示无期限，到期后自动删除服务器及所有关联数据
    var expirationDate: Date?

    /// AuthMethod：定义服务器登录认证方式。
    enum AuthMethod: Codable, Hashable, Sendable {
        case password
        case privateKey(keyID: String) // keyID references Keychain item
    }

    /// 初始化服务器实体。
    /// - Parameters:
    ///   - id: 服务器标识。
    ///   - name: 展示名称。
    ///   - host: 主机地址或域名。
    ///   - port: SSH 端口（默认 22）。
    ///   - username: 登录用户名。
    ///   - authMethod: 认证方式。
    ///   - groupID: 所属分组标识。
    init(id: UUID = UUID(), name: String, host: String, port: Int = 22, username: String, authMethod: AuthMethod, groupID: UUID? = nil, countryCode: String? = nil, iconData: Data? = nil, lastConnectedAt: Date? = nil, permissionLevel: ServerPermissionLevel = .followGlobal, expirationDate: Date? = nil) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.authMethod = authMethod
        self.groupID = groupID
        self.countryCode = countryCode
        self.iconData = iconData
        self.lastConnectedAt = lastConnectedAt
        self.permissionLevel = permissionLevel
        self.expirationDate = expirationDate
    }

    /// 将国家代码转换为国旗 emoji。
    var flagEmoji: String {
        guard let code = countryCode, code.count == 2 else { return "❓" }
        let base: UInt32 = 127397
        let scalars = code.uppercased().unicodeScalars.compactMap { UnicodeScalar(base + $0.value) }
        guard scalars.count == 2 else { return "❓" }
        return String(scalars.map { Character($0) })
    }
}
