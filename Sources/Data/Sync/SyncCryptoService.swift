/// 文件说明：SyncCryptoService，负责云同步的 E2E 加密与密钥管理。
import Foundation
import CryptoKit

/// SyncCryptoService：
/// 管理 Master Key 的生成/读取（iCloud Keychain 同步），
/// 提供 AES-256-GCM 加解密能力，按 entityType 派生不同 DEK。
/// 使用 actor 保证 cachedMasterKey 的线程安全。
actor SyncCryptoService {
    private let keychainService: KeychainServiceProtocol
    private let keychainAccount = "com.cheung.ConchTalk.sync.masterKey"
    private var cachedMasterKey: SymmetricKey?

    init(keychainService: KeychainServiceProtocol) {
        self.keychainService = keychainService
    }

    // MARK: - Master Key 管理

    /// 获取或生成 Master Key。首次调用时从 Keychain 读取，不存在则生成新密钥。
    func ensureMasterKey() throws -> SymmetricKey {
        if let cached = cachedMasterKey { return cached }

        // 尝试从 iCloud Keychain 读取
        if let existing = try readMasterKeyFromKeychain() {
            cachedMasterKey = existing
            return existing
        }

        // 生成新密钥
        let newKey = SymmetricKey(size: .bits256)
        try saveMasterKeyToKeychain(newKey)
        cachedMasterKey = newKey
        return newKey
    }

    /// 检查 Master Key 是否存在（不生成）。
    func hasMasterKey() -> Bool {
        (try? readMasterKeyFromKeychain()) != nil
    }

    /// 重置密钥（用户主动触发）。
    func resetMasterKey() throws -> SymmetricKey {
        let newKey = SymmetricKey(size: .bits256)
        try saveMasterKeyToKeychain(newKey)
        cachedMasterKey = newKey
        return newKey
    }

    // MARK: - 加解密

    /// 加密数据：HKDF 派生 DEK → AES-256-GCM 加密。
    /// 输出格式：nonce (12 bytes) || ciphertext || tag (16 bytes)
    func encrypt(_ plaintext: Data, entityType: SyncEntityType) throws -> Data {
        let masterKey = try ensureMasterKey()
        let dek = deriveKey(masterKey: masterKey, entityType: entityType)
        let nonce = AES.GCM.Nonce()
        let sealed = try AES.GCM.seal(plaintext, using: dek, nonce: nonce)
        // combined = nonce + ciphertext + tag
        guard let combined = sealed.combined else {
            throw SyncCryptoError.encryptionFailed
        }
        return combined
    }

    /// 解密数据：HKDF 派生 DEK → AES-256-GCM 解密。
    func decrypt(_ ciphertext: Data, entityType: SyncEntityType) throws -> Data {
        let masterKey = try ensureMasterKey()
        let dek = deriveKey(masterKey: masterKey, entityType: entityType)
        let sealedBox = try AES.GCM.SealedBox(combined: ciphertext)
        return try AES.GCM.open(sealedBox, using: dek)
    }

    // MARK: - 测试辅助

    /// 仅供测试使用：直接设置 master key 跳过 Keychain。
    func setMasterKeyForTesting(_ key: SymmetricKey) {
        cachedMasterKey = key
    }

    // MARK: - Private

    private func deriveKey(masterKey: SymmetricKey, entityType: SyncEntityType) -> SymmetricKey {
        let salt = "conchtalk-sync-v1".data(using: .utf8)!
        let info = entityType.rawValue.data(using: .utf8)!
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: masterKey,
            salt: salt,
            info: info,
            outputByteCount: 32
        )
    }

    private func readMasterKeyFromKeychain() throws -> SymmetricKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: keychainAccount,
            kSecAttrSynchronizable as String: kCFBooleanTrue!,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, data.count == 32 else {
            if status != errSecSuccess { throw SyncCryptoError.keychainReadFailed(status) }
            return nil
        }

        return SymmetricKey(data: data)
    }

    private func saveMasterKeyToKeychain(_ key: SymmetricKey) throws {
        let keyData = key.withUnsafeBytes { Data($0) }

        // 先删除旧密钥
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: keychainAccount,
            kSecAttrSynchronizable as String: kCFBooleanTrue!,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: keychainAccount,
            kSecValueData as String: keyData,
            kSecAttrSynchronizable as String: kCFBooleanTrue!,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ]

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw SyncCryptoError.keychainSaveFailed(status)
        }
    }
}

/// SyncCryptoError：加密服务错误类型。
enum SyncCryptoError: LocalizedError {
    case encryptionFailed
    case keychainReadFailed(OSStatus)
    case keychainSaveFailed(OSStatus)
    case masterKeyNotFound

    var errorDescription: String? {
        switch self {
        case .encryptionFailed: "Encryption failed"
        case .keychainReadFailed(let s): "Keychain read failed: \(s)"
        case .keychainSaveFailed(let s): "Keychain save failed: \(s)"
        case .masterKeyNotFound: "Master key not found in Keychain"
        }
    }
}
