/// 文件说明：ServerModel，定义服务器配置在 SwiftData 中的持久化结构。
import Foundation
import SwiftData

/// ServerModel：
/// 服务器持久化模型，记录连接参数、认证方式与分组关系。
@Model
final class ServerModel {
    @Attribute(.unique) var id: UUID
    var name: String
    var host: String
    var port: Int
    var username: String
    var authMethodRaw: String  // "password" or "privateKey:keyID"
    var countryCode: String?
    var iconData: Data?
    var lastConnectedAt: Date?
    var permissionLevelRaw: String = "followGlobal"
    // 服务器有效期，nil 表示无期限
    var expirationDate: Date?
    var connectionModeRaw: String = "direct"
    var createdAt: Date

    // MARK: - 同步字段
    var syncVersion: Int64 = 0
    var modifiedAt: Date = Date()
    var isDeleted: Bool = false
    var isRemoteMerge: Bool = false  // true = 远端合入的数据，不触发再次 push

    var group: ServerGroupModel?

    /// 初始化服务器持久化模型。
    /// - Parameters:
    ///   - id: 服务器标识。
    ///   - name: 展示名称。
    ///   - host: 主机地址。
    ///   - port: SSH 端口。
    ///   - username: 登录用户名。
    ///   - authMethodRaw: 认证方式原始值（`password` 或 `privateKey:<id>`）。
    ///   - lastConnectedAt: 最近连接时间。
    ///   - createdAt: 创建时间。
    init(id: UUID = UUID(), name: String, host: String, port: Int = 22, username: String, authMethodRaw: String, countryCode: String? = nil, iconData: Data? = nil, lastConnectedAt: Date? = nil, permissionLevelRaw: String = "followGlobal", expirationDate: Date? = nil, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.authMethodRaw = authMethodRaw
        self.countryCode = countryCode
        self.iconData = iconData
        self.lastConnectedAt = lastConnectedAt
        self.permissionLevelRaw = permissionLevelRaw
        self.expirationDate = expirationDate
        self.createdAt = createdAt
    }

    /// 转换为领域层 `Server` 实体。
    /// - Returns: 对应的领域服务器对象。
    /// - Note: 无法识别的 `authMethodRaw` 会回退为 `.password`。
    func toDomain() -> Server {
        let authMethod: Server.AuthMethod
        if authMethodRaw.hasPrefix("privateKey:") {
            let keyID = String(authMethodRaw.dropFirst("privateKey:".count))
            authMethod = .privateKey(keyID: keyID)
        } else {
            authMethod = .password
        }
        let serverPermissionLevel = ServerPermissionLevel(rawValue: permissionLevelRaw) ?? .followGlobal
        let connectionMode = ServerConnectionMode(rawValue: connectionModeRaw) ?? .direct
        return Server(id: id, name: name, host: host, port: port, username: username, authMethod: authMethod, groupID: group?.id, countryCode: countryCode, iconData: iconData, lastConnectedAt: lastConnectedAt, permissionLevel: serverPermissionLevel, expirationDate: expirationDate, connectionMode: connectionMode)
    }

    /// 从领域层 `Server` 构建持久化模型。
    /// - Parameter server: 领域服务器对象。
    /// - Returns: 对应的持久化模型实例。
    static func fromDomain(_ server: Server) -> ServerModel {
        let authRaw: String
        switch server.authMethod {
        case .password:
            authRaw = "password"
        case .privateKey(let keyID):
            authRaw = "privateKey:\(keyID)"
        }
        let model = ServerModel(id: server.id, name: server.name, host: server.host, port: server.port, username: server.username, authMethodRaw: authRaw, countryCode: server.countryCode, iconData: server.iconData, lastConnectedAt: server.lastConnectedAt, permissionLevelRaw: server.permissionLevel.rawValue, expirationDate: server.expirationDate)
        model.connectionModeRaw = server.connectionMode.rawValue
        return model
    }
}
