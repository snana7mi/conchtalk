/// 文件说明：ManageServerConnectionUseCase，封装服务器连接建立与断开流程。
import Foundation

/// ManageServerConnectionUseCase：
/// 根据服务器认证方式从安全存储读取凭据，并驱动 SSH 客户端建立/关闭连接。
final class ManageServerConnectionUseCase: @unchecked Sendable {
    private let sshClient: SSHClientProtocol
    private let keychainService: KeychainServiceProtocol

    /// 初始化连接管理用例。
    /// - Parameters:
    ///   - sshClient: SSH 客户端实现。
    ///   - keychainService: 凭据读取服务。
    init(sshClient: SSHClientProtocol, keychainService: KeychainServiceProtocol) {
        self.sshClient = sshClient
        self.keychainService = keychainService
    }

    /// 按服务器配置建立 SSH 连接。
    /// - Parameter server: 目标服务器配置。
    /// - Throws: 凭据读取失败、凭据缺失或 SSH 握手失败时抛出。
    /// - Side Effects: 触发 SSH 客户端连接状态变化。
    func connect(to server: Server) async throws {
        var password: String? = nil
        var sshKeyData: Data? = nil
        var keyPassphrase: String? = nil

        // 根据认证方式装配连接所需凭据。
        switch server.authMethod {
        case .password:
            password = try keychainService.getPassword(forServer: server.id)
        case .privateKey(let keyID):
            sshKeyData = try keychainService.getSSHKey(withID: keyID)
            keyPassphrase = try keychainService.getKeyPassphrase(forKeyID: keyID)
        }

        try await sshClient.connect(to: server, password: password, sshKeyData: sshKeyData, keyPassphrase: keyPassphrase)
    }

    /// 断开当前 SSH 连接。
    /// - Side Effects: 触发 SSH 客户端连接状态变化。
    func disconnect() async {
        await sshClient.disconnect()
    }

    /// 当前连接状态快照。
    var isConnected: Bool {
        get async { await sshClient.isConnected }
    }
}
