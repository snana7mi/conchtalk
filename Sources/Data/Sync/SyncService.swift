/// 文件说明：SyncService，云同步的编排入口，串行执行 push → pull → merge。
import Foundation
import CryptoKit

/// SyncService：
/// App 进后台时调用 `sync()`，串行执行变更收集 → 加密 → 上传 → 下载 → 解密 → 合并。
/// 使用 actor 保证同一时间只有一个同步流程在运行。
actor SyncService {
    private let crypto: SyncCryptoService
    private let apiClient: SyncAPIClientProtocol
    private let collector: SyncChangeCollector
    private let mergeEngine: SyncMergeEngine
    private let store: SwiftDataStore
    private let authService: AuthServiceProtocol

    /// 最近一次同步结果，供 UI 展示。
    struct SyncResult: Sendable {
        let success: Bool
        let pushedEntries: Int
        let pulledEntries: Int
        let skippedEntries: Int   // 本轮 pull 被隔离跳过的坏条目数（数据级永久错误）
        let prunedCount: Int
        let conflictCount: Int  // LWW 覆盖的冲突次数
        let error: String?
        let timestamp: Date
    }

    private(set) var lastResult: SyncResult?
    private var isSyncing = false

    init(crypto: SyncCryptoService, apiClient: SyncAPIClientProtocol, collector: SyncChangeCollector,
         mergeEngine: SyncMergeEngine, store: SwiftDataStore, authService: AuthServiceProtocol) {
        self.crypto = crypto
        self.apiClient = apiClient
        self.collector = collector
        self.mergeEngine = mergeEngine
        self.store = store
        self.authService = authService
    }

    /// 执行完整同步流程。供 scenePhase == .background 时调用。
    /// expiring 闭包用于检查 iOS 后台时间是否即将到期。
    func sync(isExpiring: @Sendable () -> Bool = { false }) async {
        let isLoggedIn = await authService.isLoggedIn
        guard SyncState.isEnabled, isLoggedIn else {
            print("[SyncService] Skipped: enabled=\(SyncState.isEnabled), loggedIn=\(isLoggedIn)")
            return
        }
        guard !isSyncing else {
            print("[SyncService] Skipped: already syncing")
            return
        }
        isSyncing = true
        defer { isSyncing = false }
        print("[SyncService] Starting sync (lastPushed=\(SyncState.lastSyncedVersion), lastPulledSeq=\(SyncState.lastPulledSeq), device=\(SyncState.deviceId.prefix(8))...)")

        var totalPushed = 0
        var totalPulled = 0
        var totalPruned = 0
        var skippedEntries = 0

        do {
            // --- Push ---
            var hasMore = true
            while hasMore && !isExpiring() {
                let (entries, maxVersion) = try await collector.collectChanges(
                    since: SyncState.lastSyncedVersion, batchSize: 50
                )
                if entries.isEmpty {
                    print("[SyncService] Push: no local changes to push")
                    hasMore = false; break
                }

                // 每条实体独立加密
                var pushEntries: [SyncAPIClient.PushEntry] = []
                for entry in entries {
                    let encrypted = try await crypto.encrypt(entry.jsonData, entityType: entry.entityType)
                    let base64 = encrypted.base64EncodedString()
                    pushEntries.append(SyncAPIClient.PushEntry(
                        entity_type: entry.entityType.rawValue,
                        entity_id: entry.entityId,
                        modified_at: entry.modifiedAt,
                        data: base64
                    ))
                }

                let response = try await apiClient.push(SyncAPIClient.PushRequest(
                    key_generation: SyncState.keyGeneration,
                    device_id: SyncState.deviceId,
                    entries: pushEntries
                ))

                SyncState.lastSyncedVersion = maxVersion
                totalPushed += response.stored_entries
                totalPruned += response.pruned_count
                print("[SyncService] Push batch: \(response.stored_entries) stored, \(response.pruned_count) pruned, maxVersion=\(maxVersion)")
            }

            guard !isExpiring() else {
                lastResult = SyncResult(success: true, pushedEntries: totalPushed, pulledEntries: 0,
                                       skippedEntries: skippedEntries, prunedCount: totalPruned, conflictCount: 0,
                                       error: "Interrupted by system", timestamp: Date())
                return
            }

            // --- Pull（服务端 seq 游标；单条隔离见 isPermanentDataError）---
            // 收集 server→groupID 映射，pull 完成后修复分组关系
            var serverGroupMappings: [UUID: UUID] = [:]
            let pullDecoder = JSONDecoder()
            pullDecoder.dateDecodingStrategy = .iso8601

            var cursorSeq = SyncState.lastPulledSeq
            var totalConflicts = 0
            var consecutiveFailures = 0
            print("[SyncService] Pull: starting from seq=\(cursorSeq)")
            while !isExpiring() {
                let pullResponse = try await apiClient.pull(
                    sinceSeq: cursorSeq, deviceId: SyncState.deviceId, limit: 100
                )

                print("[SyncService] Pull page: \(pullResponse.entries.count) entries, hasMore=\(pullResponse.next_cursor != nil)")
                for entry in pullResponse.entries {
                    guard let entityType = SyncEntityType(rawValue: entry.entity_type),
                          let encryptedData = Data(base64Encoded: entry.data) else {
                        skippedEntries += 1
                        consecutiveFailures += 1
                        print("[SyncService] Pull: skipped invalid entry type=\(entry.entity_type), id=\(entry.entity_id)")
                        try checkConsecutiveFailures(consecutiveFailures)
                        continue
                    }
                    do {
                        let decrypted = try await crypto.decrypt(encryptedData, entityType: entityType)

                        // 提取 server 的 groupID 映射（用于后续修复分组关系）
                        if entityType == .server,
                           let server = try? pullDecoder.decode(SwiftDataStore.SyncableServer.self, from: decrypted),
                           !server.isDeleted {
                            if let groupID = server.groupID {
                                serverGroupMappings[server.id] = groupID
                            } else {
                                serverGroupMappings.removeValue(forKey: server.id)
                            }
                        }

                        let result = try await mergeEngine.merge(entityType: entityType, jsonData: decrypted)
                        totalPulled += result.merged
                        totalConflicts += result.conflicts
                        consecutiveFailures = 0
                    } catch where isPermanentDataError(error) {
                        // 数据级永久错误：跳过该条继续，游标推进越过它是有意取舍——
                        // 损坏数据重拉一万次也解不开；服务端原数据仍在，解码修复后可 forceFullSync 补救。
                        skippedEntries += 1
                        consecutiveFailures += 1
                        print("[SyncService] Pull: skipped corrupt entry type=\(entry.entity_type), id=\(entry.entity_id), error=\(error)")
                        try checkConsecutiveFailures(consecutiveFailures)
                    }
                    // 其余错误（含 SyncMergeError、KeychainError）不被捕获，
                    // 自然上抛 → 整体 catch → 本页游标不推进 → 下次同步重试
                }

                if let nextCursor = pullResponse.next_cursor {
                    cursorSeq = nextCursor.seq
                    SyncState.lastPulledSeq = nextCursor.seq
                } else {
                    // 末页：S2 响应不含 entries[].seq，满页场景已由 next_cursor.seq 推进。
                    // Mock/测试可携带 seq 以断言末页推进；线上末页无 seq 时保持当前游标（幂等重拉）。
                    if let lastSeq = pullResponse.entries.compactMap(\.seq).last {
                        SyncState.lastPulledSeq = lastSeq
                    }
                    // 空页：游标保持不动。seq 语义下空查询走索引、代价恒低，
                    // 无需也不允许任何「跳到 now」类特判。
                    break
                }
            }

            // 修复分组关系：Server 可能在其 ServerGroup 之前被合并
            if !serverGroupMappings.isEmpty {
                try await store.rebuildServerGroupRelationships(mappings: serverGroupMappings)
            }

            // 同步成功后清理本地超过 30 天的软删除记录
            try await store.purgeSoftDeletedEntities(olderThan: SyncGarbageCollector.softDeleteRetentionDays)

            lastResult = SyncResult(success: true, pushedEntries: totalPushed, pulledEntries: totalPulled,
                                   skippedEntries: skippedEntries, prunedCount: totalPruned, conflictCount: totalConflicts,
                                   error: nil, timestamp: Date())
            print("[SyncService] Done: pushed=\(totalPushed), pulled=\(totalPulled), skipped=\(skippedEntries), pruned=\(totalPruned), conflicts=\(totalConflicts)")

            // pull 有新数据时通知 UI 刷新
            if totalPulled > 0 {
                await MainActor.run {
                    NotificationCenter.default.post(name: .syncDidPullNewData, object: nil)
                }
            }

        } catch let error as SyncAPIError where error == .keyGenerationMismatch {
            // 密钥被其他设备重置：重置同步状态，下次全量重传
            SyncState.reset()
            lastResult = SyncResult(success: false, pushedEntries: totalPushed, pulledEntries: totalPulled,
                                   skippedEntries: skippedEntries, prunedCount: totalPruned, conflictCount: 0,
                                   error: error.localizedDescription, timestamp: Date())

        } catch {
            lastResult = SyncResult(success: false, pushedEntries: totalPushed, pulledEntries: totalPulled,
                                   skippedEntries: skippedEntries, prunedCount: totalPruned, conflictCount: 0,
                                   error: error.localizedDescription, timestamp: Date())
            print("[SyncService] Sync failed: \(error)")
        }
    }

    // MARK: - Pull 错误分类与阈值

    /// 连续失败阈值：连续（每成功一条归零）跳过 10 条几乎必然是系统性故障（典型：master key 错配）。
    /// 继续逐条跳过会把全部云端数据静默跳光且游标推进到末尾，必须中止并经 lastResult.error 告警。
    private static let maxConsecutivePullFailures = 10

    /// 判定是否为数据级永久错误：数据本身损坏，重试无意义，可安全跳过。
    /// 白名单之外的一切错误（SyncMergeError、KeychainError、SwiftData、网络等）
    /// 视为环境级暂时错误，必须上抛中止、保留游标与重试机会（fail-safe：白名单跳过、默认中止）。
    private func isPermanentDataError(_ error: Error) -> Bool {
        if error is DecodingError { return true }
        if error is CryptoKitError { return true }
        return false
    }

    private func checkConsecutiveFailures(_ count: Int) throws {
        if count >= Self.maxConsecutivePullFailures {
            throw SyncServiceError.tooManyConsecutivePullFailures(count: count)
        }
    }

    // MARK: - 强制全量重新同步

    /// 重置同步游标，强制下次同步全量 push + pull。
    func forceFullSync() async {
        SyncState.reset()
        print("[SyncService] Force full sync: state reset, starting sync...")
        await sync()
    }

    // MARK: - 关闭同步

    /// 关闭云同步并删除所有云端数据。本地数据不受影响。
    /// - Returns: 是否成功。失败时 SyncState 不变，调用方应恢复 UI 状态。
    func disableAndDeleteCloudData() async -> Bool {
        do {
            _ = try await apiClient.deleteAll()
            let userId = await authService.currentUser?.id
                ?? UserDefaults.standard.string(forKey: "AuthService.cachedUserID")
            SyncState.isEnabled = false
            SyncState.disabledByUserID = userId
            SyncState.reset()
            print("[SyncService] Cloud sync disabled, cloud data deleted")
            return true
        } catch {
            print("[SyncService] Failed to delete cloud data: \(error)")
            return false
        }
    }

    // MARK: - 密钥重置

    /// 重置加密密钥：生成新 Master Key，清理云端数据，重置同步状态。
    func resetEncryptionKey() async {
        do {
            _ = try await crypto.resetMasterKey()
            _ = try await apiClient.deleteAll()
            SyncState.reset()
            SyncState.keyGeneration += 1
        } catch {
            print("[SyncService] Reset encryption key failed: \(error)")
        }
    }

}

/// SyncServiceError：同步编排层错误。
enum SyncServiceError: LocalizedError {
    /// pull 连续失败超过阈值：几乎必然是系统性问题（如密钥错配），中止并保留游标。
    case tooManyConsecutivePullFailures(count: Int)

    var errorDescription: String? {
        switch self {
        case .tooManyConsecutivePullFailures(let count):
            "Pull aborted: \(count) consecutive entry failures (possible key mismatch or data corruption)"
        }
    }
}
