// Server connection info - NOT a SwiftData model, just a value type used at the domain level
import Foundation

struct Server: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var name: String
    var host: String
    var port: Int
    var username: String
    var authMethod: AuthMethod
    var groupID: UUID?
    var lastConnectedAt: Date?

    enum AuthMethod: Codable, Hashable, Sendable {
        case password
        case privateKey(keyID: String) // keyID references Keychain item
    }

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
