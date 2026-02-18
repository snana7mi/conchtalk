import Foundation

@Observable
final class SSHSessionManager: @unchecked Sendable {
    private var clients: [UUID: NIOSSHClient] = [:]
    private var activeServerID: UUID?

    var currentClient: NIOSSHClient? {
        guard let id = activeServerID else { return nil }
        return clients[id]
    }

    func connect(to server: Server, password: String?, keychainService: KeychainServiceProtocol) async throws {
        var sshKeyData: Data? = nil
        var keyPassphrase: String? = nil

        if case .privateKey(let keyID) = server.authMethod {
            sshKeyData = try keychainService.getSSHKey(withID: keyID)
            guard sshKeyData != nil else {
                throw SSHError.authenticationFailed
            }
            keyPassphrase = try keychainService.getKeyPassphrase(forKeyID: keyID)
        }

        let client = NIOSSHClient()
        try await client.connect(to: server, password: password, sshKeyData: sshKeyData, keyPassphrase: keyPassphrase)
        clients[server.id] = client
        activeServerID = server.id
    }

    func disconnect(from serverID: UUID) async {
        if let client = clients[serverID] {
            await client.disconnect()
            clients.removeValue(forKey: serverID)
        }
        if activeServerID == serverID {
            activeServerID = nil
        }
    }

    func disconnectAll() async {
        for (_, client) in clients {
            await client.disconnect()
        }
        clients.removeAll()
        activeServerID = nil
    }

    func getClient(for serverID: UUID) -> NIOSSHClient? {
        return clients[serverID]
    }

    func setActive(serverID: UUID) {
        activeServerID = serverID
    }

    var isConnected: Bool {
        get async {
            guard let client = currentClient else { return false }
            return await client.isConnected
        }
    }
}
