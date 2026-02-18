import Foundation

final class ManageSSHKeysUseCase: @unchecked Sendable {
    private let keychainService: KeychainServiceProtocol

    init(keychainService: KeychainServiceProtocol) {
        self.keychainService = keychainService
    }

    func importKey(fromText text: String, withID keyID: String) throws {
        guard let data = text.data(using: .utf8) else {
            throw SSHKeyError.invalidKeyData
        }
        try keychainService.saveSSHKey(data, withID: keyID)
    }

    func importKey(fromData data: Data, withID keyID: String) throws {
        try keychainService.saveSSHKey(data, withID: keyID)
    }

    func deleteKey(withID keyID: String) throws {
        try keychainService.deleteSSHKey(withID: keyID)
    }

    func getKey(withID keyID: String) throws -> Data? {
        try keychainService.getSSHKey(withID: keyID)
    }
}

enum SSHKeyError: LocalizedError {
    case invalidKeyData
    case keyNotFound

    var errorDescription: String? {
        switch self {
        case .invalidKeyData: return "Invalid SSH key data"
        case .keyNotFound: return "SSH key not found"
        }
    }
}
