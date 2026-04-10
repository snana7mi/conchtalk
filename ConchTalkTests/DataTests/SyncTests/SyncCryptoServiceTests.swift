/// 文件说明：SyncCryptoServiceTests，验证加密服务的加解密与密钥派生逻辑。
import XCTest
import CryptoKit
@testable import ConchTalk

final class SyncCryptoServiceTests: XCTestCase {

    func testEncryptDecryptRoundTrip() async throws {
        let crypto = SyncCryptoService(keychainService: MockKeychainService())
        let masterKey = SymmetricKey(size: .bits256)
        await crypto.setMasterKeyForTesting(masterKey)

        let plaintext = "Hello, encrypted world!".data(using: .utf8)!
        let encrypted = try await crypto.encrypt(plaintext, entityType: .server)
        let decrypted = try await crypto.decrypt(encrypted, entityType: .server)

        XCTAssertEqual(plaintext, decrypted)
        XCTAssertNotEqual(plaintext, encrypted)
    }

    func testDifferentEntityTypesProduceDifferentCiphertext() async throws {
        let crypto = SyncCryptoService(keychainService: MockKeychainService())
        let masterKey = SymmetricKey(size: .bits256)
        await crypto.setMasterKeyForTesting(masterKey)

        let plaintext = "same data".data(using: .utf8)!
        let encrypted1 = try await crypto.encrypt(plaintext, entityType: .server)
        let encrypted2 = try await crypto.encrypt(plaintext, entityType: .message)

        // 不同 entityType 派生不同 DEK + 随机 nonce，密文必然不同
        XCTAssertNotEqual(encrypted1, encrypted2)
    }

    func testDecryptWithWrongEntityTypeFails() async throws {
        let crypto = SyncCryptoService(keychainService: MockKeychainService())
        let masterKey = SymmetricKey(size: .bits256)
        await crypto.setMasterKeyForTesting(masterKey)

        let plaintext = "secret".data(using: .utf8)!
        let encrypted = try await crypto.encrypt(plaintext, entityType: .server)

        do {
            _ = try await crypto.decrypt(encrypted, entityType: .message)
            XCTFail("Should have thrown when decrypting with wrong entity type")
        } catch {
            // 预期：CryptoKit 解密失败
        }
    }
}
