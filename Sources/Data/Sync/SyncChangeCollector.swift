/// 文件说明：SyncChangeCollector，从 SwiftData 收集待同步的变更记录并序列化。
import Foundation
import SwiftData

/// SyncChangeEntry：一条待推送的变更（一个实体一条 entry）。
struct SyncChangeEntry: Sendable {
    let entityType: SyncEntityType
    let entityId: String     // 实体的 UUID 字符串
    let jsonData: Data       // 单条实体的 JSON
    let syncVersion: Int64
    let modifiedAt: String   // ISO8601 格式的实体真实修改时间
}

/// SyncChangeCollector：
/// 查询 syncVersion > lastSyncedVersion 的记录，跨类型按全局 syncVersion 排序。
/// 只收集本地修改的记录（DB 层已过滤 isRemoteMerge == false）。
/// 收集时从 Keychain 补充读取密码和 SSH 私钥。
actor SyncChangeCollector {
    private let store: SwiftDataStore
    private let keychainService: KeychainServiceProtocol

    init(store: SwiftDataStore, keychainService: KeychainServiceProtocol) {
        self.store = store
        self.keychainService = keychainService
    }

    /// 收集待同步变更，跨类型按全局 syncVersion 排序，取前 batchSize 条。
    /// 避免某一类型填满 batch 后跳过低 version 的其他类型。
    func collectChanges(since syncVersion: Int64, batchSize: Int = 50) async throws -> (entries: [SyncChangeEntry], maxSyncVersion: Int64) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let isoFormatter = ISO8601DateFormatter()

        // 从所有类型取出变更（不限数量），稍后统一排序截取
        var all: [(syncVersion: Int64, build: () throws -> SyncChangeEntry)] = []

        let servers = try await store.fetchChangedServers(since: syncVersion, limit: batchSize)
        for s in servers {
            let captured = s
            all.append((syncVersion: s.syncVersion, build: { [keychainService] in
                var serverWithPassword = captured
                // 软删除的 tombstone 不上传密码
                if !captured.isDeleted && captured.authMethodRaw == "password" {
                    serverWithPassword = SwiftDataStore.SyncableServer(
                        id: captured.id, name: captured.name, host: captured.host, port: captured.port, username: captured.username,
                        authMethodRaw: captured.authMethodRaw, countryCode: captured.countryCode, iconData: captured.iconData,
                        lastConnectedAt: captured.lastConnectedAt, permissionLevelRaw: captured.permissionLevelRaw,
                        expirationDate: captured.expirationDate, createdAt: captured.createdAt, syncVersion: captured.syncVersion,
                        modifiedAt: captured.modifiedAt, isDeleted: captured.isDeleted, isRemoteMerge: captured.isRemoteMerge,
                        groupID: captured.groupID, password: try keychainService.getPassword(forServer: captured.id)
                    )
                }
                return SyncChangeEntry(entityType: .server, entityId: captured.id.uuidString,
                                       jsonData: try encoder.encode(serverWithPassword),
                                       syncVersion: captured.syncVersion, modifiedAt: isoFormatter.string(from: captured.modifiedAt))
            }))
        }

        let messages = try await store.fetchChangedMessages(since: syncVersion, limit: batchSize)
        for m in messages {
            let captured = m
            all.append((syncVersion: m.syncVersion, build: {
                SyncChangeEntry(entityType: .message, entityId: captured.id.uuidString,
                                jsonData: try encoder.encode(captured),
                                syncVersion: captured.syncVersion, modifiedAt: isoFormatter.string(from: captured.modifiedAt))
            }))
        }

        let sshKeys = try await store.fetchChangedSSHKeys(since: syncVersion, limit: batchSize)
        for k in sshKeys {
            let captured = k
            all.append((syncVersion: k.syncVersion, build: { [keychainService] in
                var keyWithPrivate = captured
                // 软删除的 tombstone 不上传私钥
                let privateData = captured.isDeleted ? nil : try keychainService.getSSHKey(withID: captured.id.uuidString)
                if privateData != nil {
                    keyWithPrivate = SwiftDataStore.SyncableSSHKey(
                        id: captured.id, label: captured.label, keyTypeRaw: captured.keyTypeRaw, fingerprint: captured.fingerprint,
                        publicKeyOpenSSH: captured.publicKeyOpenSSH, sourceRaw: captured.sourceRaw, createdAt: captured.createdAt,
                        privateKeyData: privateData, syncVersion: captured.syncVersion, modifiedAt: captured.modifiedAt,
                        isDeleted: captured.isDeleted, isRemoteMerge: captured.isRemoteMerge
                    )
                }
                return SyncChangeEntry(entityType: .sshKey, entityId: captured.id.uuidString,
                                       jsonData: try encoder.encode(keyWithPrivate),
                                       syncVersion: captured.syncVersion, modifiedAt: isoFormatter.string(from: captured.modifiedAt))
            }))
        }

        let groups = try await store.fetchChangedServerGroups(since: syncVersion, limit: batchSize)
        for g in groups {
            let captured = g
            all.append((syncVersion: g.syncVersion, build: {
                SyncChangeEntry(entityType: .serverGroup, entityId: captured.id.uuidString,
                                jsonData: try encoder.encode(captured),
                                syncVersion: captured.syncVersion, modifiedAt: isoFormatter.string(from: captured.modifiedAt))
            }))
        }

        let memories = try await store.fetchChangedMemories(since: syncVersion, limit: batchSize)
        for m in memories {
            let captured = m
            all.append((syncVersion: m.syncVersion, build: {
                SyncChangeEntry(entityType: .memory, entityId: captured.id.uuidString,
                                jsonData: try encoder.encode(captured),
                                syncVersion: captured.syncVersion, modifiedAt: isoFormatter.string(from: captured.modifiedAt))
            }))
        }

        let memoryEntries = try await store.fetchChangedMemoryEntries(since: syncVersion, limit: batchSize)
        for e in memoryEntries {
            let captured = e
            all.append((syncVersion: e.syncVersion, build: {
                SyncChangeEntry(entityType: .memoryEntry, entityId: captured.id.uuidString,
                                jsonData: try encoder.encode(captured),
                                syncVersion: captured.syncVersion, modifiedAt: isoFormatter.string(from: captured.modifiedAt))
            }))
        }

        let profiles = try await store.fetchChangedSystemProfiles(since: syncVersion, limit: batchSize)
        for p in profiles {
            let captured = p
            all.append((syncVersion: p.syncVersion, build: {
                SyncChangeEntry(entityType: .systemProfile, entityId: captured.serverID.uuidString,
                                jsonData: try encoder.encode(captured),
                                syncVersion: captured.syncVersion, modifiedAt: isoFormatter.string(from: captured.modifiedAt))
            }))
        }

        let approvalRules = try await store.fetchChangedApprovalRules(since: syncVersion, limit: batchSize)
        for r in approvalRules {
            let captured = r
            all.append((syncVersion: r.syncVersion, build: {
                SyncChangeEntry(entityType: .approvalRule, entityId: captured.id.uuidString,
                                jsonData: try encoder.encode(captured),
                                syncVersion: captured.syncVersion, modifiedAt: isoFormatter.string(from: captured.modifiedAt))
            }))
        }

        // 按全局 syncVersion 排序，取前 batchSize 条
        all.sort { $0.syncVersion < $1.syncVersion }
        let selected = all.prefix(batchSize)

        var results: [SyncChangeEntry] = []
        var maxVersion = syncVersion
        for item in selected {
            do {
                let entry = try item.build()
                results.append(entry)
                maxVersion = max(maxVersion, entry.syncVersion)
            } catch let error as KeychainError {
                // 凭据读取失败（典型：锁屏 errSecInteractionNotAllowed）：截断本批次。
                // push 水位线（lastSyncedVersion）是全局单调游标，若跳过失败实体继续推后续条目，
                // 水位线将越过失败实体使其永久失去重推机会——截断保证水位线绝不越过任何未成功推送的实体。
                // 收敛性：下一轮排序后第一条就是失败实体，build 即抛 → entries 为空 → push 段 break，
                // 水位线不被污染；解锁后凭据可读，自然续推。
                print("[SyncChangeCollector] 凭据读取失败，截断本批次: \(error)")
                break
            }
        }

        return (results, maxVersion)
    }
}
