/// 文件说明：SyncMergeEngine，实现 Last-Write-Wins 合并策略。
import Foundation
import SwiftData

/// SyncMergeEngine：
/// 将从云端 pull 下来的解密数据与本地 SwiftData 进行 LWW 合并。
/// 比较 modifiedAt 时间戳，较新者胜出。
/// 仅在远端胜出时将密码和 SSH 私钥写回 Keychain（LWW 门控，经 onRemoteWin 闭包注入 store 的原子操作）。
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
            // 凭据写回闭包：仅在远端胜出时由 store 在 save() 前调用（LWW 门控）。
            // 写回失败必须可见：元数据不持久化、错误上抛，下次 pull 重试。
            var credentialWriter: (@Sendable () throws -> Void)? = nil
            if let password = remote.password, !remote.isDeleted {
                credentialWriter = { [keychainService] in
                    try keychainService.savePassword(password, forServer: remote.id)
                }
            }
            do {
                let count = try await store.mergeRemoteServer(remote, onRemoteWin: credentialWriter)
                return (merged: count, conflicts: 0)
            } catch let error as KeychainError {
                throw SyncMergeError.credentialWriteFailed(
                    entityType: .server, entityId: remote.id.uuidString, underlying: error)
            }
        case .message:
            let remote = try decoder.decode(SwiftDataStore.SyncableMessage.self, from: jsonData)
            return try await store.mergeRemoteMessage(remote)
        case .sshKey:
            let remote = try decoder.decode(SwiftDataStore.SyncableSSHKey.self, from: jsonData)
            // 私钥写回闭包：语义同 server 分支的密码写回。
            var credentialWriter: (@Sendable () throws -> Void)? = nil
            if let privateKeyData = remote.privateKeyData, !remote.isDeleted {
                credentialWriter = { [keychainService] in
                    try keychainService.saveSSHKey(privateKeyData, withID: remote.id.uuidString)
                }
            }
            do {
                let count = try await store.mergeRemoteSSHKey(remote, onRemoteWin: credentialWriter)
                return (merged: count, conflicts: 0)
            } catch let error as KeychainError {
                throw SyncMergeError.credentialWriteFailed(
                    entityType: .sshKey, entityId: remote.id.uuidString, underlying: error)
            }
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

/// SyncMergeError：merge 过程中的本机环境级错误（可重试），与数据级永久错误区分。
/// 问题 2 的 pull 隔离逻辑依赖此类型区分「数据坏（跳过）」与「环境暂时错误（中止重试）」，
/// 此错误绝不能被隔离逻辑吞掉。
enum SyncMergeError: Error {
    /// 凭据写回 Keychain 失败。此时元数据未持久化，整条目应在下次 pull 重试。
    case credentialWriteFailed(entityType: SyncEntityType, entityId: String, underlying: Error)
}
