/// 文件说明：SSHKeyMigrationService，负责将已有服务器的内联 SSH 密钥迁移为统一管理的密钥条目。
import Foundation

/// SSHKeyMigrationService：
/// 在应用更新后首次启动时执行一次性迁移，将各服务器关联的私钥提升为独立的 `SSHKey` 实体，
/// 以支持新的密钥统一管理机制。迁移过程为非致命操作，失败时会在下次启动重试。
enum SSHKeyMigrationService {

    /// UserDefaults 标记键，标识迁移是否已完成。
    private static let migrationCompletedKey = "sshKeyMigrationCompleted"

    /// 执行一次性密钥迁移。
    /// - Parameters:
    ///   - store: SwiftData 持久化存储。
    ///   - keychainService: Keychain 安全存储服务。
    /// - Note:
    ///   - 仅在首次调用时执行，完成后通过 UserDefaults 标记跳过后续调用。
    ///   - 遍历所有使用私钥认证的服务器，为其创建对应的 `SSHKey` 实体。
    ///   - 尝试从 Keychain 读取私钥数据并解析公钥信息（类型、指纹、OpenSSH 格式）。
    ///   - 迁移失败不会中断应用启动流程，将在下次启动时重试。
    static func migrateIfNeeded(store: SwiftDataStore, keychainService: KeychainServiceProtocol) async {
        // 已完成迁移则直接返回
        guard !UserDefaults.standard.bool(forKey: migrationCompletedKey) else { return }

        do {
            let servers = try await store.fetchServers()

            for server in servers {
                // 仅处理使用私钥认证的服务器
                guard case .privateKey(let keyID) = server.authMethod else { continue }
                guard let keyUUID = UUID(uuidString: keyID) else { continue }

                // 若对应 SSHKey 已存在则跳过
                let existing = try await store.fetchSSHKey(byID: keyUUID)
                guard existing == nil else { continue }

                // 尝试从已存储的私钥数据中推导公钥信息
                var keyType: SSHKey.KeyType = .unknown
                var fingerprint = ""
                var publicKeyOpenSSH = ""

                if let keyData = try? keychainService.getSSHKey(withID: keyID) {
                    let passphrase = try? keychainService.getKeyPassphrase(forKeyID: keyID)
                    if let info = SSHPublicKeyEncoder.derivePublicKeyInfo(fromPrivateKeyData: keyData, passphrase: passphrase) {
                        keyType = info.keyType
                        fingerprint = info.fingerprint
                        publicKeyOpenSSH = info.publicKeyOpenSSH
                    }
                }

                let sshKey = SSHKey(
                    id: keyUUID,
                    label: "Key for \(server.name)",
                    keyType: keyType,
                    fingerprint: fingerprint,
                    publicKeyOpenSSH: publicKeyOpenSSH,
                    createdAt: Date(),
                    source: .imported
                )

                try await store.saveSSHKey(sshKey)
            }

            UserDefaults.standard.set(true, forKey: migrationCompletedKey)
        } catch {
            // 迁移失败为非致命错误，下次启动时将重试
        }
    }
}
