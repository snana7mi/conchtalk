/// 文件说明：SSHKeyManagementViewModel，负责 SSH 密钥管理的业务逻辑与状态驱动。
import Foundation

/// SSHKeyManagementViewModel：管理界面状态，并协调密钥的生成、导入、更新与删除。
@Observable
final class SSHKeyManagementViewModel {
    var keys: [SSHKey] = []
    var isGenerating = false
    var errorMessage: String?
    var showError = false

    private let store: SwiftDataStore
    private let keychainService: any KeychainServiceProtocol

    /// 初始化视图模型，并注入所需业务依赖。
    init(store: SwiftDataStore, keychainService: any KeychainServiceProtocol) {
        self.store = store
        self.keychainService = keychainService
    }

    /// loadKeys：加载并同步所有已管理的密钥。
    func loadKeys() async {
        do {
            keys = try await store.fetchSSHKeys()
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    /// generateKey：生成新密钥对并持久化存储，返回新建密钥的 ID。
    @discardableResult
    func generateKey(type: SSHKey.KeyType, label: String) async -> UUID? {
        isGenerating = true
        defer { isGenerating = false }

        do {
            // 密钥生成（尤其 RSA-4096 的 SecKeyCreateRandomKey）是 CPU 密集同步操作，可耗时数秒。
            // 本 VM 默认 MainActor 隔离，直接同步执行会冻结 UI——放到后台 detached 执行，
            // GeneratedKeyPair 是 Sendable，可安全跨隔离返回。
            let result: GeneratedKeyPair
            switch type {
            case .ed25519:
                result = await Task.detached(priority: .userInitiated) {
                    SSHKeyGenerationService.generateEd25519()
                }.value
            case .rsa4096:
                result = try await Task.detached(priority: .userInitiated) {
                    try SSHKeyGenerationService.generateRSA4096()
                }.value
            case .ecdsaP256:
                result = await Task.detached(priority: .userInitiated) {
                    SSHKeyGenerationService.generateECDSAP256()
                }.value
            case .unknown:
                return nil
            }

            let sshKey = SSHKey(
                label: label,
                keyType: result.keyType,
                fingerprint: result.fingerprint,
                publicKeyOpenSSH: result.publicKeyOpenSSH,
                source: .generated
            )

            // 将私钥数据保存到 Keychain
            try keychainService.saveSSHKey(result.privateKeyData, withID: sshKey.id.uuidString)

            // 将元数据保存到 SwiftData
            try await store.saveSSHKey(sshKey)

            await loadKeys()
            return sshKey.id
        } catch {
            errorMessage = error.localizedDescription
            showError = true
            return nil
        }
    }

    /// importKey：导入已有密钥并持久化存储。
    func importKey(privateKeyText: String, passphrase: String?, label: String) async {
        guard let keyData = privateKeyText.data(using: .utf8) else {
            errorMessage = String(localized: "Unable to encode key data", bundle: LanguageSettings.currentBundle)
            showError = true
            return
        }

        // 从私钥数据中解析公钥信息
        let info = SSHPublicKeyEncoder.derivePublicKeyInfo(fromPrivateKeyData: keyData, passphrase: passphrase)

        let sshKey = SSHKey(
            label: label,
            keyType: info?.keyType ?? .unknown,
            fingerprint: info?.fingerprint ?? "",
            publicKeyOpenSSH: info?.publicKeyOpenSSH ?? "",
            source: .imported
        )

        do {
            // 将私钥数据保存到 Keychain
            try keychainService.saveSSHKey(keyData, withID: sshKey.id.uuidString)

            // 若提供了口令则一并保存
            if let passphrase, !passphrase.isEmpty {
                try keychainService.saveKeyPassphrase(passphrase, forKeyID: sshKey.id.uuidString)
            }

            // 将元数据保存到 SwiftData
            try await store.saveSSHKey(sshKey)

            await loadKeys()
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    /// updateLabel：更新密钥标签。
    func updateLabel(_ key: SSHKey, newLabel: String) async {
        var updated = key
        updated.label = newLabel
        do {
            try await store.updateSSHKey(updated)
            await loadKeys()
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    /// replaceKey：替换已有密钥的私钥数据，重新解析公钥信息。
    /// 保持密钥 ID 不变，所有引用该密钥的服务器自动生效。
    func replaceKey(_ key: SSHKey, newPrivateKeyText: String, passphrase: String?) async -> SSHKey? {
        guard let keyData = newPrivateKeyText.data(using: .utf8) else {
            errorMessage = String(localized: "Unable to encode key data", bundle: LanguageSettings.currentBundle)
            showError = true
            return nil
        }

        let info = SSHPublicKeyEncoder.derivePublicKeyInfo(fromPrivateKeyData: keyData, passphrase: passphrase)

        var updated = key
        updated.keyType = info?.keyType ?? .unknown
        updated.fingerprint = info?.fingerprint ?? ""
        updated.publicKeyOpenSSH = info?.publicKeyOpenSSH ?? ""

        do {
            // 更新 Keychain 中的私钥数据
            try keychainService.saveSSHKey(keyData, withID: key.id.uuidString)

            // 更新口令
            if let passphrase, !passphrase.isEmpty {
                try keychainService.saveKeyPassphrase(passphrase, forKeyID: key.id.uuidString)
            } else {
                try? keychainService.deleteKeyPassphrase(forKeyID: key.id.uuidString)
            }

            // 更新 SwiftData 元数据
            try await store.updateSSHKey(updated)
            await loadKeys()
            return updated
        } catch {
            errorMessage = error.localizedDescription
            showError = true
            return nil
        }
    }

    /// deleteKey：删除密钥及其关联的 Keychain 条目。
    /// 先删 SwiftData 元数据，再删 Keychain 私钥，避免数据库删除失败时留下无私钥的壳记录。
    func deleteKey(_ key: SSHKey) async {
        do {
            // 先从 SwiftData 删除元数据（失败时 Keychain 数据保持完整，不影响连接）
            try await store.deleteSSHKey(key.id)

            // SwiftData 成功后再清理 Keychain（即使失败，也仅残留孤立的 Keychain 条目，不影响功能）
            try? keychainService.deleteSSHKey(withID: key.id.uuidString)
            try? keychainService.deleteKeyPassphrase(forKeyID: key.id.uuidString)

            await loadKeys()
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    /// serversUsingKey：查询使用指定密钥的服务器列表。
    func serversUsingKey(_ keyID: UUID) async -> [Server] {
        do {
            let servers = try await store.fetchServers()
            return servers.filter { server in
                if case .privateKey(let id) = server.authMethod {
                    return id == keyID.uuidString
                }
                return false
            }
        } catch {
            return []
        }
    }
}
