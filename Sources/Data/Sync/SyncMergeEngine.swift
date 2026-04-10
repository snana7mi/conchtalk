/// 文件说明：SyncMergeEngine，实现 Last-Write-Wins 合并策略。
import Foundation
import SwiftData

/// SyncMergeEngine：
/// 将从云端 pull 下来的解密数据与本地 SwiftData 进行 LWW 合并。
/// 比较 modifiedAt 时间戳，较新者胜出。
/// 合并时将密码和 SSH 私钥写回 Keychain。
actor SyncMergeEngine {
    private let store: SwiftDataStore
    private let keychainService: KeychainServiceProtocol

    init(store: SwiftDataStore, keychainService: KeychainServiceProtocol) {
        self.store = store
        self.keychainService = keychainService
    }

    /// 合并远端变更到本地。返回 (merged, conflicts) tuple。
    func merge(entityType: SyncEntityType, jsonData: Data) async throws -> (merged: Int, conflicts: Int) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        switch entityType {
        case .server:
            let remote = try decoder.decode(SwiftDataStore.SyncableServer.self, from: jsonData)
            let count = try await store.mergeRemoteServer(remote)
            // 恢复密码到 Keychain
            if let password = remote.password, !remote.isDeleted {
                try? keychainService.savePassword(password, forServer: remote.id)
            }
            return (merged: count, conflicts: 0)
        case .message:
            let remote = try decoder.decode(SwiftDataStore.SyncableMessage.self, from: jsonData)
            return try await store.mergeRemoteMessage(remote)
        case .sshKey:
            let remote = try decoder.decode(SwiftDataStore.SyncableSSHKey.self, from: jsonData)
            let count = try await store.mergeRemoteSSHKey(remote)
            // 恢复 SSH 私钥到 Keychain
            if let privateKeyData = remote.privateKeyData, !remote.isDeleted {
                try? keychainService.saveSSHKey(privateKeyData, withID: remote.id.uuidString)
            }
            return (merged: count, conflicts: 0)
        case .serverGroup:
            let remote = try decoder.decode(SwiftDataStore.SyncableServerGroup.self, from: jsonData)
            return try await store.mergeRemoteServerGroup(remote)
        case .memory:
            let remote = try decoder.decode(SwiftDataStore.SyncableMemory.self, from: jsonData)
            return try await store.mergeRemoteMemory(remote)
        case .memoryEntry:
            let remote = try decoder.decode(SwiftDataStore.SyncableMemoryEntry.self, from: jsonData)
            return try await store.mergeRemoteMemoryEntry(remote)
        case .systemProfile:
            let remote = try decoder.decode(SwiftDataStore.SyncableSystemProfile.self, from: jsonData)
            return try await store.mergeRemoteSystemProfile(remote)
        }
    }
}
