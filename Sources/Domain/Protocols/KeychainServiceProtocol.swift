import Foundation

protocol KeychainServiceProtocol: Sendable {
    func savePassword(_ password: String, forServer serverID: UUID) throws
    func getPassword(forServer serverID: UUID) throws -> String?
    func deletePassword(forServer serverID: UUID) throws
    func saveSSHKey(_ keyData: Data, withID keyID: String) throws
    func getSSHKey(withID keyID: String) throws -> Data?
    func deleteSSHKey(withID keyID: String) throws
    func saveKeyPassphrase(_ passphrase: String, forKeyID keyID: String) throws
    func getKeyPassphrase(forKeyID keyID: String) throws -> String?
    func deleteKeyPassphrase(forKeyID keyID: String) throws
}
