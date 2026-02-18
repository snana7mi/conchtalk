import Foundation

final class ManageServerConnectionUseCase: @unchecked Sendable {
    private let sshClient: SSHClientProtocol
    private let keychainService: KeychainServiceProtocol

    init(sshClient: SSHClientProtocol, keychainService: KeychainServiceProtocol) {
        self.sshClient = sshClient
        self.keychainService = keychainService
    }

    func connect(to server: Server) async throws {
        var password: String? = nil
        var sshKeyData: Data? = nil
        var keyPassphrase: String? = nil

        switch server.authMethod {
        case .password:
            password = try keychainService.getPassword(forServer: server.id)
        case .privateKey(let keyID):
            sshKeyData = try keychainService.getSSHKey(withID: keyID)
            keyPassphrase = try keychainService.getKeyPassphrase(forKeyID: keyID)
        }

        try await sshClient.connect(to: server, password: password, sshKeyData: sshKeyData, keyPassphrase: keyPassphrase)
    }

    func disconnect() async {
        await sshClient.disconnect()
    }

    var isConnected: Bool {
        get async { await sshClient.isConnected }
    }
}
