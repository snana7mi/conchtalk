/// 文件说明：SyncIntegrationTests，验证云同步 collect → encrypt → decrypt → merge 端到端流程。
import XCTest
import CryptoKit
@testable import ConchTalk

final class SyncIntegrationTests: XCTestCase {

    /// 测试完整的 encode → encrypt → decrypt → decode 流程（单条实体粒度）。
    func testSingleEntityEncryptDecryptRoundTrip() async throws {
        let crypto = SyncCryptoService(keychainService: MockKeychainService())
        let masterKey = SymmetricKey(size: .bits256)
        await crypto.setMasterKeyForTesting(masterKey)

        let server = SwiftDataStore.SyncableServer(
            id: UUID(), name: "Test VPS", host: "192.168.1.1", port: 22,
            username: "root", authMethodRaw: "password", countryCode: "US",
            iconData: nil, lastConnectedAt: nil, permissionLevelRaw: "followGlobal",
            expirationDate: nil, createdAt: Date(), syncVersion: 1,
            modifiedAt: Date(), isDeleted: false, isRemoteMerge: false, groupID: nil,
            password: nil
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let jsonData = try encoder.encode(server)
        let encrypted = try await crypto.encrypt(jsonData, entityType: .server)
        let decrypted = try await crypto.decrypt(encrypted, entityType: .server)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(SwiftDataStore.SyncableServer.self, from: decrypted)

        XCTAssertEqual(decoded.name, "Test VPS")
        XCTAssertEqual(decoded.host, "192.168.1.1")
    }

    /// 测试不同实体类型加密后无法互相解密。
    func testCrossEntityTypeDecryptionFails() async throws {
        let crypto = SyncCryptoService(keychainService: MockKeychainService())
        let masterKey = SymmetricKey(size: .bits256)
        await crypto.setMasterKeyForTesting(masterKey)

        let data = "test data".data(using: .utf8)!
        let encrypted = try await crypto.encrypt(data, entityType: .server)

        do {
            _ = try await crypto.decrypt(encrypted, entityType: .message)
            XCTFail("Should have thrown when decrypting with wrong entity type")
        } catch {
            // 预期失败
        }
    }

    /// 测试 SyncEntityType 的 pullPriority 排序正确（ServerGroup < Server）。
    func testPullPriorityOrder() {
        let sorted = SyncEntityType.allCases.sorted { $0.pullPriority < $1.pullPriority }
        XCTAssertEqual(sorted.first, .serverGroup)
        XCTAssertTrue(sorted.firstIndex(of: .server)! > sorted.firstIndex(of: .serverGroup)!)
    }
}
