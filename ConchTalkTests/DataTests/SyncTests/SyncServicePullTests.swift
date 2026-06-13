/// 文件说明：SyncServicePullTests，验证 pull 循环的单条隔离、连续失败阈值与游标推进语义。
import Testing
@testable import ConchTalk
import Foundation
import SwiftData
import CryptoKit
import Security

@Suite("SyncService Pull", .serialized)
struct SyncServicePullTests {

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

    private func makeService(
        keychain: MockKeychainService = MockKeychainService()
    ) async throws -> (service: SyncService, api: MockSyncAPIClient, crypto: SyncCryptoService) {
        let store = try makeInMemoryStore()
        let crypto = SyncCryptoService(keychainService: keychain)
        await crypto.setMasterKeyForTesting(SymmetricKey(size: .bits256))
        let api = MockSyncAPIClient()
        let auth = MockAuthService()
        auth.isLoggedIn = true
        let collector = SyncChangeCollector(store: store, keychainService: keychain)
        let merge = SyncMergeEngine(store: store, keychainService: keychain)
        let service = SyncService(crypto: crypto, apiClient: api, collector: collector,
                                  mergeEngine: merge, store: store, authService: auth)
        return (service, api, crypto)
    }

    private func withCleanSyncState(_ body: () async throws -> Void) async rethrows {
        let wasEnabled = SyncState.isEnabled
        SyncState.reset()
        SyncState.isEnabled = true
        defer {
            SyncState.isEnabled = wasEnabled
            SyncState.reset()
        }
        try await body()
    }

    private func makeEncryptedServerEntry(
        crypto: SyncCryptoService, id: UUID = UUID(), password: String? = nil, seq: Int64? = 1
    ) async throws -> SyncAPIClient.PullEntry {
        let server = SwiftDataStore.SyncableServer(
            id: id, name: "Remote-\(id.uuidString.prefix(4))", host: "10.0.0.1", port: 22,
            username: "root", authMethodRaw: "password", countryCode: nil, iconData: nil,
            lastConnectedAt: nil, permissionLevelRaw: "followGlobal", expirationDate: nil,
            createdAt: Date(timeIntervalSince1970: 0), syncVersion: 1,
            modifiedAt: Date(timeIntervalSince1970: 1_000), isDeleted: false,
            isRemoteMerge: false, groupID: nil, password: password
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let encrypted = try await crypto.encrypt(try encoder.encode(server), entityType: .server)
        return SyncAPIClient.PullEntry(
            seq: seq, entity_type: "server", entity_id: id.uuidString,
            modified_at: "2026-01-01T00:00:00Z", device_id: "other-device",
            data: encrypted.base64EncodedString()
        )
    }

    private func makeCorruptEntry(id: UUID = UUID(), seq: Int64? = 1) -> SyncAPIClient.PullEntry {
        SyncAPIClient.PullEntry(
            seq: seq, entity_type: "server", entity_id: id.uuidString,
            modified_at: "2026-01-01T00:00:00Z", device_id: "other-device",
            data: Data(repeating: 0x42, count: 64).base64EncodedString()
        )
    }

    // MARK: - 问题 2：单条隔离

    @Test("单条坏数据跳过，其余条目正常合并")
    func pull_corruptEntry_skipsAndContinues() async throws {
        try await withCleanSyncState {
            let (service, api, crypto) = try await makeService()
            let good1 = try await makeEncryptedServerEntry(crypto: crypto)
            let good2 = try await makeEncryptedServerEntry(crypto: crypto)
            api.pullResponses = [SyncAPIClient.PullResponse(
                entries: [good1, makeCorruptEntry(), good2], next_cursor: nil)]

            await service.sync()

            let result = await service.lastResult
            #expect(result?.success == true)
            #expect(result?.skippedEntries == 1)
            #expect(result?.pulledEntries == 2)
        }
    }

    @Test("非法 base64 条目并入 skipped 计数")
    func pull_invalidBase64_countsAsSkipped() async throws {
        try await withCleanSyncState {
            let (service, api, crypto) = try await makeService()
            let bad = SyncAPIClient.PullEntry(
                seq: 1, entity_type: "server", entity_id: UUID().uuidString,
                modified_at: "2026-01-01T00:00:00Z", device_id: "other-device",
                data: "!!!not-base64!!!"
            )
            let good = try await makeEncryptedServerEntry(crypto: crypto)
            api.pullResponses = [SyncAPIClient.PullResponse(entries: [bad, good], next_cursor: nil)]

            await service.sync()

            let result = await service.lastResult
            #expect(result?.success == true)
            #expect(result?.skippedEntries == 1)
            #expect(result?.pulledEntries == 1)
        }
    }

    @Test("凭据写回失败（环境级错误）中止本轮且游标不推进")
    func pull_credentialWriteFailure_abortsAndKeepsCursor() async throws {
        try await withCleanSyncState {
            let keychain = MockKeychainService()
            let (service, api, crypto) = try await makeService(keychain: keychain)
            let serverID = UUID()
            keychain.passwordWriteErrors[serverID] = KeychainError.saveFailed(errSecInteractionNotAllowed)
            let entry = try await makeEncryptedServerEntry(crypto: crypto, id: serverID, password: "pw")
            api.pullResponses = [SyncAPIClient.PullResponse(entries: [entry], next_cursor: nil)]

            await service.sync()

            let result = await service.lastResult
            #expect(result?.success == false)
            #expect(result?.skippedEntries == 0)
            #expect(SyncState.lastPulledSeq == 0)
        }
    }

    @Test("连续 10 条坏数据触发阈值中止，游标不推进")
    func pull_consecutiveFailuresExceedThreshold_aborts() async throws {
        try await withCleanSyncState {
            let (service, api, _) = try await makeService()
            api.pullResponses = [SyncAPIClient.PullResponse(
                entries: (0..<10).map { _ in makeCorruptEntry() }, next_cursor: nil)]

            await service.sync()

            let result = await service.lastResult
            #expect(result?.success == false)
            #expect(result?.error?.contains("consecutive") == true)
            #expect(SyncState.lastPulledSeq == 0)
        }
    }

    @Test("坏好交替 12 条不触发阈值（成功归零计数），全部处理完成")
    func pull_consecutiveCounterResetsOnSuccess() async throws {
        try await withCleanSyncState {
            let (service, api, crypto) = try await makeService()
            var entries: [SyncAPIClient.PullEntry] = []
            for _ in 0..<6 {
                entries.append(makeCorruptEntry())
                entries.append(try await makeEncryptedServerEntry(crypto: crypto))
            }
            api.pullResponses = [SyncAPIClient.PullResponse(entries: entries, next_cursor: nil)]

            await service.sync()

            let result = await service.lastResult
            #expect(result?.success == true)
            #expect(result?.skippedEntries == 6)
            #expect(result?.pulledEntries == 6)
        }
    }

    // MARK: - 问题 4：seq 游标

    @Test("分页响应依次推进 seq 游标并持久化")
    func pull_usesSeqCursor_persistsLastPulledSeq() async throws {
        try await withCleanSyncState {
            let (service, api, crypto) = try await makeService()
            let e1 = try await makeEncryptedServerEntry(crypto: crypto, seq: 5)
            let e2 = try await makeEncryptedServerEntry(crypto: crypto, seq: 9)
            api.pullResponses = [
                SyncAPIClient.PullResponse(entries: [e1], next_cursor: SyncAPIClient.PullSeqCursor(seq: 5)),
                SyncAPIClient.PullResponse(entries: [e2], next_cursor: nil),
            ]

            await service.sync()

            #expect(api.receivedPullSeqs == [0, 5])
            #expect(SyncState.lastPulledSeq == 9)
        }
    }

    @Test("末页（next_cursor == nil）推进游标到最后一条 entry 的 seq")
    func pull_finalPage_advancesToLastEntrySeq() async throws {
        try await withCleanSyncState {
            let (service, api, crypto) = try await makeService()
            let e1 = try await makeEncryptedServerEntry(crypto: crypto, seq: 3)
            let e2 = try await makeEncryptedServerEntry(crypto: crypto, seq: 7)
            api.pullResponses = [SyncAPIClient.PullResponse(entries: [e1, e2], next_cursor: nil)]

            await service.sync()

            #expect(SyncState.lastPulledSeq == 7)
        }
    }

    @Test("空响应游标保持不动（取代旧「跳 now」行为的回归保护）")
    func pull_emptyResult_keepsCursorUnchanged() async throws {
        try await withCleanSyncState {
            let (service, api, _) = try await makeService()
            api.pullResponses = [SyncAPIClient.PullResponse(entries: [], next_cursor: nil)]

            await service.sync()

            let result = await service.lastResult
            #expect(result?.success == true)
            #expect(SyncState.lastPulledSeq == 0)
        }
    }

    @Test("旧版时间戳游标残值被忽略，升级后从 seq=0 全量拉取（兼容期回归）")
    func pull_legacyTimestampCursorIgnored_startsFromSeqZero() async throws {
        try await withCleanSyncState {
            UserDefaults.standard.set("2026-05-01T00:00:00Z", forKey: "SyncState.lastPullTimestamp")
            defer { UserDefaults.standard.removeObject(forKey: "SyncState.lastPullTimestamp") }
            let (service, api, _) = try await makeService()

            await service.sync()

            #expect(api.receivedPullSeqs.first == 0)
        }
    }

    @Test("S2 响应形态：entries 无 seq 时由 next_cursor.seq 推进游标")
    func pull_s2ResponseShape_advancesViaNextCursorOnly() async throws {
        try await withCleanSyncState {
            let (service, api, crypto) = try await makeService()
            let entry = try await makeEncryptedServerEntry(crypto: crypto, seq: nil)
            api.pullResponses = [
                SyncAPIClient.PullResponse(
                    entries: [entry], next_cursor: SyncAPIClient.PullSeqCursor(seq: 12)),
                SyncAPIClient.PullResponse(entries: [], next_cursor: nil),
            ]

            await service.sync()

            #expect(api.receivedPullSeqs == [0, 12])
            #expect(SyncState.lastPulledSeq == 12)
        }
    }
}
