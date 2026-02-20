/// 文件说明：SSHSessionManager，负责多服务器 SSH 客户端实例的生命周期管理与路由。
import Foundation

// MARK: - ConnectionState

/// 连接状态枚举：描述 SSH 会话的当前连接阶段。
enum ConnectionState: Sendable {
    case connected
    case disconnected
    case reconnecting
}

// MARK: - LastConnectionParams

/// 记录上一次成功连接的参数，用于断线重连。
private struct LastConnectionParams {
    let server: Server
    let password: String?
    let keychainService: KeychainServiceProtocol
}

// MARK: - SSHSessionManager

/// SSHSessionManager：
/// 维护「服务器 ID -> SSH 客户端」映射，统一处理连接建立、断开、当前活跃会话切换。
/// 支持 OS 自动探测与断线自动重连。
@Observable
final class SSHSessionManager {
    private var clients: [UUID: NIOSSHClient] = [:]
    private var activeServerID: UUID?

    /// 每个服务器检测到的远端操作系统名称。
    private var detectedOS: [UUID: String] = [:]

    /// 当前连接状态，用于驱动 UI 展示。
    var connectionState: ConnectionState = .disconnected

    /// 上一次成功连接的参数缓存，用于自动重连。
    private var lastConnectionParams: [UUID: LastConnectionParams] = [:]

    var currentClient: NIOSSHClient? {
        guard let id = activeServerID else { return nil }
        return clients[id]
    }

    // MARK: - 连接管理

    /// 为指定服务器建立 SSH 连接并登记为当前活跃会话。
    /// - Parameters:
    ///   - server: 目标服务器配置。
    ///   - password: 密码认证凭据（密码登录时使用）。
    ///   - keychainService: 用于读取私钥与口令的安全存储服务。
    /// - Throws: 凭据缺失、凭据读取失败或底层连接失败时抛出。
    /// - Side Effects:
    ///   - 可能读取 Keychain 中的私钥/口令。
    ///   - 成功后会写入 `clients` 并更新 `activeServerID`。
    ///   - 连接成功后自动探测远端 OS。
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
        connectionState = .connected

        // 缓存连接参数以供重连使用
        lastConnectionParams[server.id] = LastConnectionParams(
            server: server,
            password: password,
            keychainService: keychainService
        )

        // 自动探测远端操作系统
        await detectOS(for: server.id, client: client)
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
            connectionState = .disconnected
        }
        lastConnectionParams.removeValue(forKey: serverID)
        detectedOS.removeValue(forKey: serverID)
    }

    /// 断开全部 SSH 连接并清空会话缓存。
    /// - Side Effects: 清空 `clients`、`activeServerID`、连接参数缓存与 OS 探测结果。
    func disconnectAll() async {
        for (_, client) in clients {
            await client.disconnect()
        }
        clients.removeAll()
        activeServerID = nil
        connectionState = .disconnected
        lastConnectionParams.removeAll()
        detectedOS.removeAll()
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

    // MARK: - OS 探测

    /// 在远端执行 `uname -s` 以探测操作系统类型。
    /// - Parameters:
    ///   - serverID: 服务器标识。
    ///   - client: 已建立连接的 SSH 客户端。
    /// - Note: 探测失败时静默降级为 "Linux"。
    private func detectOS(for serverID: UUID, client: NIOSSHClient) async {
        do {
            let output = try await client.execute(command: "uname -s")
            let osName = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if !osName.isEmpty {
                detectedOS[serverID] = osName
            } else {
                detectedOS[serverID] = "Linux"
            }
        } catch {
            detectedOS[serverID] = "Linux"
        }
    }

    /// 获取指定服务器检测到的操作系统名称。
    /// - Parameter serverID: 服务器标识。
    /// - Returns: 操作系统名称（如 "Linux"、"Darwin"、"FreeBSD"）；未检测到时默认返回 "Linux"。
    func getDetectedOS(for serverID: UUID) -> String {
        return detectedOS[serverID] ?? "Linux"
    }

    // MARK: - 自动重连

    /// 检查当前活跃连接是否存活，若已断开则尝试自动重连。
    /// - Parameters:
    ///   - server: 目标服务器配置（优先使用；为空时回退到缓存参数）。
    ///   - password: 密码认证凭据。
    ///   - keychainService: 安全存储服务。
    /// - Note: 重连失败时将状态置为 `.disconnected`，不再抛出异常。
    func checkAndReconnect(server: Server? = nil, password: String? = nil, keychainService: KeychainServiceProtocol? = nil) async {
        guard let serverID = activeServerID else { return }

        let connected = await isConnected
        if connected {
            connectionState = .connected
            return
        }

        // 尝试从缓存或传入参数中获取重连所需信息
        let params: LastConnectionParams?
        if let server, let keychainService {
            params = LastConnectionParams(server: server, password: password, keychainService: keychainService)
        } else {
            params = lastConnectionParams[serverID]
        }

        guard let reconnectParams = params else {
            connectionState = .disconnected
            return
        }

        connectionState = .reconnecting

        // 清理旧的客户端实例
        if let oldClient = clients[serverID] {
            await oldClient.disconnect()
            clients.removeValue(forKey: serverID)
        }

        do {
            try await connect(
                to: reconnectParams.server,
                password: reconnectParams.password,
                keychainService: reconnectParams.keychainService
            )
            // connect() 内部已将 connectionState 置为 .connected
        } catch {
            connectionState = .disconnected
        }
    }
}
