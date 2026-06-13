/// 文件说明：SyncChangeCollectorTests，验证凭据读取失败时的批次截断语义与 nil/throw 区分。
import Testing
@testable import ConchTalk
import Foundation
import SwiftData
import Security

@Suite("SyncChangeCollector")
struct SyncChangeCollectorTests {

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

    private func makeCollector() throws -> (collector: SyncChangeCollector, store: SwiftDataStore, keychain: MockKeychainService) {
        let store = try makeInMemoryStore()
        let keychain = MockKeychainService()
        return (SyncChangeCollector(store: store, keychainService: keychain), store, keychain)
    }

    // MARK: - 用例

    @Test("密码不存在（errSecItemNotFound 语义）时实体照常收集，password 为 nil")
    func collect_passwordNotFound_pushesEntityWithNilPassword() async throws {
        let (collector, store, _) = try makeCollector()
        try await store.saveServer(TestFixtures.makeServer())

        let (entries, _) = try await collector.collectChanges(since: 0, batchSize: 50)

        #expect(entries.count == 1)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(SwiftDataStore.SyncableServer.self, from: entries[0].jsonData)
        #expect(decoded.password == nil)
    }

    @Test("第 2 个实体密码读取失败时截断本批次，水位线停在第 1 条")
    func collect_passwordReadFails_truncatesBatchAtFailedEntity() async throws {
        let (collector, store, keychain) = try makeCollector()
        let s1 = TestFixtures.makeServer(name: "s1")
        let s2 = TestFixtures.makeServer(name: "s2")
        let s3 = TestFixtures.makeServer(name: "s3")
        try await store.saveServer(s1)
        try await store.saveServer(s2)
        try await store.saveServer(s3)

        let baseline = try await collector.collectChanges(since: 0, batchSize: 50)
        #expect(baseline.entries.count == 3)
        let firstVersion = baseline.entries[0].syncVersion

        keychain.passwordReadErrors[s2.id] = KeychainError.readFailed(errSecInteractionNotAllowed)
        let (entries, maxVersion) = try await collector.collectChanges(since: 0, batchSize: 50)

        #expect(entries.count == 1)
        #expect(entries[0].entityId == s1.id.uuidString)
        #expect(maxVersion == firstVersion)
    }

    @Test("第 1 个实体即读取失败时返回空且水位线等于入参")
    func collect_firstEntityReadFails_returnsEmptyWithUnchangedVersion() async throws {
        let (collector, store, keychain) = try makeCollector()
        let server = TestFixtures.makeServer()
        try await store.saveServer(server)
        keychain.passwordReadErrors[server.id] = KeychainError.readFailed(errSecInteractionNotAllowed)

        let (entries, maxVersion) = try await collector.collectChanges(since: 0, batchSize: 50)

        #expect(entries.isEmpty)
        #expect(maxVersion == 0)
    }

    @Test("SSH 私钥读取失败同样截断")
    func collect_sshKeyReadFails_truncates() async throws {
        let (collector, store, keychain) = try makeCollector()
        let key = SSHKey(label: "k1", keyType: .ed25519, source: .generated)
        try await store.saveSSHKey(key)
        keychain.sshKeyReadErrors[key.id.uuidString] = KeychainError.readFailed(errSecInteractionNotAllowed)

        let (entries, maxVersion) = try await collector.collectChanges(since: 0, batchSize: 50)

        #expect(entries.isEmpty)
        #expect(maxVersion == 0)
    }

    @Test("tombstone 不读 Keychain（注入读取错误也照常收集）")
    func collect_tombstone_skipsCredentialRead() async throws {
        let (collector, store, keychain) = try makeCollector()
        let server = TestFixtures.makeServer()
        try await store.saveServer(server)
        try await store.deleteServer(server.id)
        keychain.passwordReadErrors[server.id] = KeychainError.readFailed(errSecInteractionNotAllowed)

        let (entries, _) = try await collector.collectChanges(since: 0, batchSize: 50)

        let serverEntries = entries.filter { $0.entityType == .server }
        #expect(serverEntries.count == 1)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(SwiftDataStore.SyncableServer.self, from: serverEntries[0].jsonData)
        #expect(decoded.isDeleted == true)
    }

    @Test("fetchChangedServers 软删除 tombstone 上报 isDeleted == true")
    func fetchChangedServers_tombstoneReportsIsDeleted() async throws {
        let store = try makeInMemoryStore()
        let server = TestFixtures.makeServer()
        try await store.saveServer(server)
        try await store.deleteServer(server.id)

        let changed = try await store.fetchChangedServers(since: 0, limit: 10)
        let tombstone = try #require(changed.first(where: { $0.id == server.id }))
        #expect(tombstone.isDeleted == true)
    }

    @Test("fetchChangedSSHKeys 软删除 tombstone 上报 isDeleted == true")
    func fetchChangedSSHKeys_tombstoneReportsIsDeleted() async throws {
        let store = try makeInMemoryStore()
        let key = SSHKey(label: "k1", keyType: .ed25519, source: .generated)
        try await store.saveSSHKey(key)
        try await store.deleteSSHKey(key.id)

        let changed = try await store.fetchChangedSSHKeys(since: 0, limit: 10)
        let tombstone = try #require(changed.first(where: { $0.id == key.id }))
        #expect(tombstone.isDeleted == true)
    }
}
