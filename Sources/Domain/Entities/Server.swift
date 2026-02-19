// Server connection info - NOT a SwiftData model, just a value type used at the domain level
/// 文件说明：Server，定义远端服务器连接配置的领域实体模型。
import Foundation

/// Server：
/// 表示一台可连接服务器的核心信息，包括地址、认证方式、分组及最近连接时间。
struct Server: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var name: String
    var host: String
    var port: Int
    var username: String
    var authMethod: AuthMethod
    var groupID: UUID?
    var lastConnectedAt: Date?

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
    init(id: UUID = UUID(), name: String, host: String, port: Int = 22, username: String, authMethod: AuthMethod, groupID: UUID? = nil) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.authMethod = authMethod
        self.groupID = groupID
    }
}
