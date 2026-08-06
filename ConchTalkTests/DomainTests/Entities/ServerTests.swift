/// 文件说明：ServerTests，测试 Server 领域实体的核心属性、认证方式、哈希一致性及编解码行为。
import Testing
@testable import ConchTalk
import Foundation

@Suite("Server Entity")
struct ServerTests {

    // MARK: - 默认端口

    @Test("Default port is 22")
    func defaultPort() {
        let server = Server(name: "My Server", host: "example.com", username: "root", authMethod: .password)
        #expect(server.port == 22)
    }

    // MARK: - 认证方式

    @Test("Password auth method")
    func passwordAuthMethod() {
        let server = TestFixtures.makeServer(authMethod: .password)
        #expect(server.authMethod == .password)
    }

    @Test("PrivateKey auth with keyID")
    func privateKeyAuthMethod() {
        let keyID = "my-key-id-123"
        let server = TestFixtures.makeServer(authMethod: .privateKey(keyID: keyID))
        guard case .privateKey(let id) = server.authMethod else {
            #expect(Bool(false), "Expected privateKey auth method")
            return
        }
        #expect(id == keyID)
    }

    // MARK: - Hashable

    @Test("Hashable: identical servers produce same hash, different IDs coexist in Set")
    func hashableConsistency() {
        let id = UUID()
        let server1 = TestFixtures.makeServer(id: id)
        let server2 = TestFixtures.makeServer(id: id)
        #expect(server1.hashValue == server2.hashValue)

        let server3 = TestFixtures.makeServer()
        let set: Set<Server> = [server1, server3]
        #expect(set.count == 2)
    }

    // MARK: - Codable

    @Test("Codable round-trip with password auth")
    func codableRoundTripPasswordAuth() throws {
        let original = TestFixtures.makeServer(authMethod: .password)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Server.self, from: data)
        #expect(decoded.id == original.id)
        #expect(decoded.name == original.name)
        #expect(decoded.host == original.host)
        #expect(decoded.port == original.port)
        #expect(decoded.username == original.username)
        #expect(decoded.authMethod == original.authMethod)
    }

    @Test("Codable round-trip with privateKey auth")
    func codableRoundTripPrivateKeyAuth() throws {
        let keyID = "encoded-key-id"
        let original = TestFixtures.makeServer(authMethod: .privateKey(keyID: keyID))
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Server.self, from: data)
        #expect(decoded.authMethod == .privateKey(keyID: keyID))
    }

    // MARK: - 默认权限等级

    @Test("Default permissionLevel is followGlobal")
    func defaultPermissionLevel() {
        let server = Server(name: "My Server", host: "example.com", username: "root", authMethod: .password)
        #expect(server.permissionLevel == .followGlobal)
    }
}
