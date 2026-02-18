import Foundation
import SwiftData

@Model
final class ServerModel {
    @Attribute(.unique) var id: UUID
    var name: String
    var host: String
    var port: Int
    var username: String
    var authMethodRaw: String  // "password" or "privateKey:keyID"
    var lastConnectedAt: Date?
    var createdAt: Date

    var group: ServerGroupModel?

    @Relationship(deleteRule: .cascade)
    var conversations: [ConversationModel] = []

    init(id: UUID = UUID(), name: String, host: String, port: Int = 22, username: String, authMethodRaw: String, lastConnectedAt: Date? = nil, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.authMethodRaw = authMethodRaw
        self.lastConnectedAt = lastConnectedAt
        self.createdAt = createdAt
    }

    func toDomain() -> Server {
        let authMethod: Server.AuthMethod
        if authMethodRaw.hasPrefix("privateKey:") {
            let keyID = String(authMethodRaw.dropFirst("privateKey:".count))
            authMethod = .privateKey(keyID: keyID)
        } else {
            authMethod = .password
        }
        return Server(id: id, name: name, host: host, port: port, username: username, authMethod: authMethod, groupID: group?.id)
    }

    static func fromDomain(_ server: Server) -> ServerModel {
        let authRaw: String
        switch server.authMethod {
        case .password:
            authRaw = "password"
        case .privateKey(let keyID):
            authRaw = "privateKey:\(keyID)"
        }
        return ServerModel(id: server.id, name: server.name, host: server.host, port: server.port, username: server.username, authMethodRaw: authRaw)
    }
}
