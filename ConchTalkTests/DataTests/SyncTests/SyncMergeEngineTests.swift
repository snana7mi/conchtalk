/// 文件说明：SyncMergeEngineTests，验证 LWW 合并时凭据写回的门控与原子性。
import Testing
@testable import ConchTalk
import Foundation
import SwiftData
import Security

@Suite("SyncMergeEngine")
struct SyncMergeEngineTests {

    // MARK: - Helpers

    private func makeInMemoryStore() throws -> SwiftDataStore {
        let schema = Schema([
            ServerModel.self,
            MessageModel.self,
            ServerGroupModel.self,
            SSHKeyModel.self,
            MemoryModel.self,
            MemoryEntryModel.self,
            SystemProfileModel.self,
        ])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        return SwiftDataStore(modelContainer: container)
    }

    private func makeEngine() throws -> (engine: SyncMergeEngine, keychain: MockKeychainService) {
        let store = try makeInMemoryStore()
        let keychain = MockKeychainService()
        return (SyncMergeEngine(store: store, keychainService: keychain), keychain)
    }

    /// 构造可控 modifiedAt 的远端 server 实体（整秒时间戳，规避 ISO8601 亚秒截断）。
    private func makeSyncableServer(
        id: UUID, modifiedAt: Date, password: String?, isDeleted: Bool = false
    ) -> SwiftDataStore.SyncableServer {
        SwiftDataStore.SyncableServer(
            id: id, name: "Remote", host: "10.0.0.1", port: 22, username: "root",
            authMethodRaw: "password", countryCode: nil, iconData: nil,
            lastConnectedAt: nil, permissionLevelRaw: "followGlobal",
            expirationDate: nil, createdAt: Date(timeIntervalSince1970: 0),
            syncVersion: 1, modifiedAt: modifiedAt, isDeleted: isDeleted,
            isRemoteMerge: false, groupID: nil, password: password
        )
    }

    /// 构造可控 modifiedAt 的远端 SSH key 实体。
    private func makeSyncableSSHKey(
        id: UUID, modifiedAt: Date, privateKeyData: Data?, isDeleted: Bool = false
    ) -> SwiftDataStore.SyncableSSHKey {
        SwiftDataStore.SyncableSSHKey(
            id: id, label: "key", keyTypeRaw: "ed25519", fingerprint: "SHA256:abc",
            publicKeyOpenSSH: "ssh-ed25519 AAAA", sourceRaw: "generated",
            createdAt: Date(timeIntervalSince1970: 0), privateKeyData: privateKeyData,
            syncVersion: 1, modifiedAt: modifiedAt, isDeleted: isDeleted, isRemoteMerge: false
        )
    }

    private func encode<T: Encodable>(_ entity: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(entity)
    }

    // MARK: - Server 分支

    @Test("远端较新时密码写入 Keychain")
    func mergeServer_remoteWins_writesPasswordToKeychain() async throws {
        let (engine, keychain) = try makeEngine()
        let id = UUID()
        _ = try await engine.merge(entityType: .server, jsonData: encode(
            makeSyncableServer(id: id, modifiedAt: Date(timeIntervalSince1970: 1_000), password: "old-pw")))

        let result = try await engine.merge(entityType: .server, jsonData: encode(
            makeSyncableServer(id: id, modifiedAt: Date(timeIntervalSince1970: 2_000), password: "new-pw")))

        #expect(result.merged == 1)
        #expect(try keychain.getPassword(forServer: id) == "new-pw")
    }

    @Test("本地较新时远端旧密码不得进入 Keychain（核心回归）")
    func mergeServer_localWins_doesNotTouchKeychain() async throws {
        let (engine, keychain) = try makeEngine()
        let id = UUID()
        _ = try await engine.merge(entityType: .server, jsonData: encode(
            makeSyncableServer(id: id, modifiedAt: Date(timeIntervalSince1970: 2_000), password: "local-new-pw")))
        #expect(try keychain.getPassword(forServer: id) == "local-new-pw")

        let result = try await engine.merge(entityType: .server, jsonData: encode(
            makeSyncableServer(id: id, modifiedAt: Date(timeIntervalSince1970: 1_000), password: "stale-pw")))

        #expect(result.merged == 0)
        #expect(try keychain.getPassword(forServer: id) == "local-new-pw")
    }

    @Test("本地无记录时新建实体并写入密码")
    func mergeServer_newEntity_writesCredential() async throws {
        let (engine, keychain) = try makeEngine()
        let id = UUID()

        let result = try await engine.merge(entityType: .server, jsonData: encode(
            makeSyncableServer(id: id, modifiedAt: Date(timeIntervalSince1970: 1_000), password: "fresh-pw")))

        #expect(result.merged == 1)
        #expect(try keychain.getPassword(forServer: id) == "fresh-pw")
    }

    @Test("远端 tombstone 胜出时不写凭据")
    func mergeServer_tombstone_doesNotWriteCredential() async throws {
        let (engine, keychain) = try makeEngine()
        let id = UUID()
        _ = try await engine.merge(entityType: .server, jsonData: encode(
            makeSyncableServer(id: id, modifiedAt: Date(timeIntervalSince1970: 1_000), password: "alive-pw")))

        let result = try await engine.merge(entityType: .server, jsonData: encode(
            makeSyncableServer(id: id, modifiedAt: Date(timeIntervalSince1970: 2_000), password: "zombie-pw", isDeleted: true)))

        #expect(result.merged == 1)
        #expect(try keychain.getPassword(forServer: id) == "alive-pw")
    }

    @Test("Keychain 写回失败时抛 SyncMergeError 且元数据不持久化（rollback）")
    func mergeServer_keychainWriteFails_throwsAndDoesNotPersistMetadata() async throws {
        let (engine, keychain) = try makeEngine()
        let id = UUID()
        _ = try await engine.merge(entityType: .server, jsonData: encode(
            makeSyncableServer(id: id, modifiedAt: Date(timeIntervalSince1970: 1_000), password: "old-pw")))

        keychain.passwordWriteErrors[id] = KeychainError.saveFailed(errSecInteractionNotAllowed)
        let remote = makeSyncableServer(id: id, modifiedAt: Date(timeIntervalSince1970: 2_000), password: "new-pw")

        await #expect(throws: SyncMergeError.self) {
            _ = try await engine.merge(entityType: .server, jsonData: encode(remote))
        }
        #expect(try keychain.getPassword(forServer: id) == "old-pw")

        keychain.passwordWriteErrors[id] = nil
        let retried = try await engine.merge(entityType: .server, jsonData: encode(remote))
        #expect(retried.merged == 1)
        #expect(try keychain.getPassword(forServer: id) == "new-pw")
    }

    // MARK: - SSHKey 分支

    @Test("SSH 私钥侧：本地较新时远端旧私钥不得进入 Keychain")
    func mergeSSHKey_localWins_doesNotTouchKeychain() async throws {
        let (engine, keychain) = try makeEngine()
        let id = UUID()
        let localKey = Data("local-private-key".utf8)
        let staleKey = Data("stale-private-key".utf8)
        _ = try await engine.merge(entityType: .sshKey, jsonData: encode(
            makeSyncableSSHKey(id: id, modifiedAt: Date(timeIntervalSince1970: 2_000), privateKeyData: localKey)))
        #expect(try keychain.getSSHKey(withID: id.uuidString) == localKey)

        let result = try await engine.merge(entityType: .sshKey, jsonData: encode(
            makeSyncableSSHKey(id: id, modifiedAt: Date(timeIntervalSince1970: 1_000), privateKeyData: staleKey)))

        #expect(result.merged == 0)
        #expect(try keychain.getSSHKey(withID: id.uuidString) == localKey)
    }

    @Test("SSH 私钥侧：Keychain 写回失败时抛 SyncMergeError 且 rollback")
    func mergeSSHKey_keychainWriteFails_throwsAndRollsBack() async throws {
        let (engine, keychain) = try makeEngine()
        let id = UUID()
        let oldKey = Data("old-private-key".utf8)
        let newKey = Data("new-private-key".utf8)
        _ = try await engine.merge(entityType: .sshKey, jsonData: encode(
            makeSyncableSSHKey(id: id, modifiedAt: Date(timeIntervalSince1970: 1_000), privateKeyData: oldKey)))

        keychain.sshKeyWriteErrors[id.uuidString] = KeychainError.saveFailed(errSecInteractionNotAllowed)
        let remote = makeSyncableSSHKey(id: id, modifiedAt: Date(timeIntervalSince1970: 2_000), privateKeyData: newKey)

        await #expect(throws: SyncMergeError.self) {
            _ = try await engine.merge(entityType: .sshKey, jsonData: encode(remote))
        }
        #expect(try keychain.getSSHKey(withID: id.uuidString) == oldKey)

        keychain.sshKeyWriteErrors[id.uuidString] = nil
        let retried = try await engine.merge(entityType: .sshKey, jsonData: encode(remote))
        #expect(retried.merged == 1)
        #expect(try keychain.getSSHKey(withID: id.uuidString) == newKey)
    }
}
