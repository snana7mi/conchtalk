/// 文件说明：SSHSessionManager，负责多服务器 SSH 客户端实例的生命周期管理与路由。
import Foundation

/// SSHSessionManager：
/// 维护「服务器 ID -> SSH 客户端」映射，统一处理连接建立、断开、当前活跃会话切换。
@Observable
final class SSHSessionManager: @unchecked Sendable {
    private var clients: [UUID: NIOSSHClient] = [:]
    private var activeServerID: UUID?

    var currentClient: NIOSSHClient? {
        guard let id = activeServerID else { return nil }
        return clients[id]
    }

    /// 为指定服务器建立 SSH 连接并登记为当前活跃会话。
    /// - Parameters:
    ///   - server: 目标服务器配置。
    ///   - password: 密码认证凭据（密码登录时使用）。
    ///   - keychainService: 用于读取私钥与口令的安全存储服务。
    /// - Throws: 凭据缺失、凭据读取失败或底层连接失败时抛出。
    /// - Side Effects:
    ///   - 可能读取 Keychain 中的私钥/口令。
    ///   - 成功后会写入 `clients` 并更新 `activeServerID`。
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

    /// 断开指定服务器的 SSH 连接并移除缓存客户端。
    /// - Parameter serverID: 服务器标识。
    /// - Side Effects:
    ///   - 会关闭底层连接并从 `clients` 删除对应实例。
    ///   - 若该服务器为当前活跃会话，会清空 `activeServerID`。
    func disconnect(from serverID: UUID) async {
        if let client = clients[serverID] {
            await client.disconnect()
            clients.removeValue(forKey: serverID)
        }
        if activeServerID == serverID {
            activeServerID = nil
        }
    }

    /// 断开全部 SSH 连接并清空会话缓存。
    /// - Side Effects: 清空 `clients` 与 `activeServerID`。
    func disconnectAll() async {
        for (_, client) in clients {
            await client.disconnect()
        }
        clients.removeAll()
        activeServerID = nil
    }

    /// 获取指定服务器对应的客户端实例。
    /// - Parameter serverID: 服务器标识。
    /// - Returns: 客户端实例；不存在时返回 `nil`。
    func getClient(for serverID: UUID) -> NIOSSHClient? {
        return clients[serverID]
    }

    /// 设置当前活跃服务器。
    /// - Parameter serverID: 服务器标识。
    /// - Note: 该方法仅切换活跃 ID，不会主动建立连接。
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
