/// 文件说明：ManageSSHKeysUseCaseTests，测试 SSH 密钥导入、查询与删除的业务用例。
import Testing
@testable import ConchTalk
import Foundation

@Suite("ManageSSHKeysUseCase")
struct ManageSSHKeysUseCaseTests {
    private struct MockKeychainError: Error {}

    // MARK: - 辅助属性

    private func makeSUT() -> (useCase: ManageSSHKeysUseCase, keychain: MockKeychainService) {
        let keychain = MockKeychainService()
        let useCase = ManageSSHKeysUseCase(keychainService: keychain)
        return (useCase, keychain)
    }

    // MARK: - 从文本导入密钥

    @Test("Import key from text stores UTF-8 data in keychain")
    func importKeyFromText() throws {
        let (useCase, keychain) = makeSUT()
        let keyText = "-----BEGIN OPENSSH PRIVATE KEY-----\ntest-key-content\n-----END OPENSSH PRIVATE KEY-----"
        let keyID = "test-key-id"

        try useCase.importKey(fromText: keyText, withID: keyID)

        let stored = try keychain.getSSHKey(withID: keyID)
        #expect(stored == keyText.data(using: .utf8))
    }

    // MARK: - 从 Data 导入密钥

    @Test("Import key from Data stores exact bytes in keychain")
    func importKeyFromData() throws {
        let (useCase, keychain) = makeSUT()
        let keyData = Data([0x00, 0x01, 0x02, 0xFF, 0xFE])
        let keyID = "binary-key-id"

        try useCase.importKey(fromData: keyData, withID: keyID)

        let stored = try keychain.getSSHKey(withID: keyID)
        #expect(stored == keyData)
    }

    // MARK: - 删除密钥

    @Test("Delete key removes it from keychain")
    func deleteKey() throws {
        let (useCase, keychain) = makeSUT()
        let keyID = "key-to-delete"
        let keyData = Data("some-key".utf8)

        try useCase.importKey(fromData: keyData, withID: keyID)
        try useCase.deleteKey(withID: keyID)

        let stored = try keychain.getSSHKey(withID: keyID)
        #expect(stored == nil)
    }

    // MARK: - 获取已存在的密钥

    @Test("Get existing key returns correct data")
    func getExistingKey() throws {
        let (useCase, _) = makeSUT()
        let keyID = "existing-key"
        let keyData = Data("my-private-key-content".utf8)

        try useCase.importKey(fromData: keyData, withID: keyID)

        let retrieved = try useCase.getKey(withID: keyID)
        #expect(retrieved == keyData)
    }

    // MARK: - 获取不存在的密钥

    @Test("Get nonexistent key returns nil")
    func getNonexistentKey() throws {
        let (useCase, _) = makeSUT()

        let retrieved = try useCase.getKey(withID: "nonexistent-key-id")
        #expect(retrieved == nil)
    }

    @Test("Keychain save error is propagated on import from text")
    func importKeyFromTextPropagatesSaveError() {
        let (useCase, keychain) = makeSUT()
        keychain.shouldThrow = MockKeychainError()

        #expect(throws: MockKeychainError.self) {
            try useCase.importKey(fromText: "test-key", withID: "key-id")
        }
    }

    @Test("Keychain save error is propagated on import from data")
    func importKeyFromDataPropagatesSaveError() {
        let (useCase, keychain) = makeSUT()
        keychain.shouldThrow = MockKeychainError()

        #expect(throws: MockKeychainError.self) {
            try useCase.importKey(fromData: Data("abc".utf8), withID: "key-id")
        }
    }

    @Test("Keychain delete error is propagated")
    func deleteKeyPropagatesDeleteError() {
        let (useCase, keychain) = makeSUT()
        keychain.shouldThrow = MockKeychainError()

        #expect(throws: MockKeychainError.self) {
            try useCase.deleteKey(withID: "key-id")
        }
    }

    @Test("Keychain get error is propagated")
    func getKeyPropagatesReadError() {
        let (useCase, keychain) = makeSUT()
        keychain.shouldThrow = MockKeychainError()

        #expect(throws: MockKeychainError.self) {
            _ = try useCase.getKey(withID: "key-id")
        }
    }
}
