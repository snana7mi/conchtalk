import Foundation

protocol SSHClientProtocol: Sendable {
    func connect(to server: Server, password: String?, sshKeyData: Data?, keyPassphrase: String?) async throws
    func disconnect() async
    func execute(command: String) async throws -> String
    var isConnected: Bool { get async }
}
