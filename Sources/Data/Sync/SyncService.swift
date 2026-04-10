/// 文件说明：SyncService，云同步的编排入口，串行执行 push → pull → merge。
import Foundation

/// SyncService：
/// App 进后台时调用 `sync()`，串行执行变更收集 → 加密 → 上传 → 下载 → 解密 → 合并。
/// 使用 actor 保证同一时间只有一个同步流程在运行。
actor SyncService {
    private let crypto: SyncCryptoService
    private let apiClient: SyncAPIClient
    private let collector: SyncChangeCollector
    private let mergeEngine: SyncMergeEngine
    private let store: SwiftDataStore
    private let authService: AuthService

    /// 最近一次同步结果，供 UI 展示。
    struct SyncResult: Sendable {
        let success: Bool
        let pushedEntries: Int
        let pulledEntries: Int
        let prunedCount: Int
        let conflictCount: Int  // LWW 覆盖的冲突次数
        let error: String?
        let timestamp: Date
    }

    private(set) var lastResult: SyncResult?
    private var isSyncing = false

    init(crypto: SyncCryptoService, apiClient: SyncAPIClient, collector: SyncChangeCollector,
         mergeEngine: SyncMergeEngine, store: SwiftDataStore, authService: AuthService) {
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
        print("[SyncService] Starting sync (lastPushed=\(SyncState.lastSyncedVersion), lastPull=\(SyncState.lastPullTimestamp), device=\(SyncState.deviceId.prefix(8))...)")

        var totalPushed = 0
        var totalPulled = 0
        var totalPruned = 0

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
                                       prunedCount: totalPruned, conflictCount: 0, error: "Interrupted by system", timestamp: Date())
                return
            }

            // --- Pull（复合游标避免 off-by-one）---
            // 收集 server→groupID 映射，pull 完成后修复分组关系
            var serverGroupMappings: [UUID: UUID] = [:]
            let pullDecoder = JSONDecoder()
            pullDecoder.dateDecodingStrategy = .iso8601

            var cursorSince = SyncState.lastPullTimestamp
            var cursorSinceId = ""
            var totalConflicts = 0
            print("[SyncService] Pull: starting from cursor=\(cursorSince)")
            while !isExpiring() {
                let pullResponse = try await apiClient.pull(
                    since: cursorSince, sinceId: cursorSinceId,
                    deviceId: SyncState.deviceId
                )

                print("[SyncService] Pull page: \(pullResponse.entries.count) entries, hasMore=\(pullResponse.next_cursor != nil)")
                for entry in pullResponse.entries {
                    guard let entityType = SyncEntityType(rawValue: entry.entity_type),
                          let encryptedData = Data(base64Encoded: entry.data) else {
                        print("[SyncService] Pull: skipped invalid entry type=\(entry.entity_type), id=\(entry.entity_id)")
                        continue
                    }

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
                }

                if let cursor = pullResponse.next_cursor {
                    cursorSince = cursor.since
                    cursorSinceId = cursor.since_id
                    SyncState.lastPullTimestamp = cursor.since
                } else {
                    if let lastEntry = pullResponse.entries.last {
                        SyncState.lastPullTimestamp = lastEntry.modified_at
                    } else if pullResponse.entries.isEmpty && cursorSince == "1970-01-01T00:00:00Z" {
                        // 单设备场景：pull 排除自身 device_id 后返回空，更新游标避免每次启动重复 recovery sync
                        let now = ISO8601DateFormatter().string(from: Date())
                        SyncState.lastPullTimestamp = now
                    }
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
                                   prunedCount: totalPruned, conflictCount: totalConflicts, error: nil, timestamp: Date())
            print("[SyncService] Done: pushed=\(totalPushed), pulled=\(totalPulled), pruned=\(totalPruned), conflicts=\(totalConflicts)")

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
                                   prunedCount: totalPruned, conflictCount: 0, error: error.localizedDescription, timestamp: Date())

        } catch {
            lastResult = SyncResult(success: false, pushedEntries: totalPushed, pulledEntries: totalPulled,
                                   prunedCount: totalPruned, conflictCount: 0, error: error.localizedDescription, timestamp: Date())
            print("[SyncService] Sync failed: \(error)")
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
