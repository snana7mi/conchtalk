/// 文件说明：SSHSessionManager，负责多服务器 SSH 客户端实例的生命周期管理与路由。
import Foundation

// MARK: - LastConnectionParams

/// 记录上一次成功连接的参数，用于断线重连。
private struct LastConnectionParams {
    let server: Server
    let password: String?
    let keychainService: KeychainServiceProtocol
}

// MARK: - SSHSessionManager

/// SSHSessionManager：
/// 维护「服务器 ID -> SSH 客户端」映射，统一处理连接建立、断开与重连。
/// 支持 OS 自动探测与断线自动重连。
/// `@MainActor` 保证 AsyncMutex 内部状态由 MainActor 串行保护。
@Observable
@MainActor
final class SSHSessionManager {
    private var clients: [UUID: NIOSSHClient] = [:]

    /// 每个服务器检测到的远端操作系统名称。
    private var detectedOS: [UUID: String] = [:]

    /// 每个服务器探测到的工具能力。
    private var detectedCapabilities: [UUID: ServerCapabilities] = [:]

    /// 当前已建立 SSH 连接的服务器 ID 集合，供 UI 观察（如对话列表的绿色发光效果）。
    var activeConnectionIDs: Set<UUID> = []

    /// 每个服务器的连接建立时间。
    private var connectionStartTimes_: [UUID: Date] = [:]

    /// 上一次成功连接的参数缓存，用于自动重连。
    private var lastConnectionParams: [UUID: LastConnectionParams] = [:]

    /// SwiftData 存储（由 DependencyContainer 注入），用于持久化系统环境探测结果。
    var store: SwiftDataStore?

    /// per-server 锁，connect/disconnect 共享同一把锁。
    private var serverLocks: [UUID: AsyncMutex] = [:]

    /// 重连退避策略。
    private let reconnectPolicy = SSHReconnectPolicy()
    /// 每服务器重连进度（attempt, maxAttempts），供 UI 观察。
    private(set) var reconnectProgress: [UUID: (attempt: Int, maxAttempts: Int)] = [:]
    /// 每服务器是否正在执行退避重连循环（防止并发触发）。
    private var isReconnecting: [UUID: Bool] = [:]

    /// SSH exec channel 的 shell 初始化前缀。
    /// non-login non-interactive shell 不会自动加载用户配置，导致 nvm、~/.local/bin 等
    /// 路径不在 PATH 中。在探测脚本和 ACP 启动命令前 source 常见配置文件来补全 PATH。
    nonisolated static let shellInitPrefix = """
    for f in ~/.bashrc ~/.profile ~/.bash_profile; do [ -f "$f" ] && . "$f" 2>/dev/null; done; \
    export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"; [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh" 2>/dev/null; \

    """

    /// 获取或创建指定服务器的 per-server 锁。
    private func lockForServer(_ serverID: UUID) -> AsyncMutex {
        if let lock = serverLocks[serverID] { return lock }
        let lock = AsyncMutex()
        serverLocks[serverID] = lock
        return lock
    }

    // MARK: - 连接管理

    /// 确保到指定服务器的 SSH 连接已建立（快速路径 + 加锁 + double-check）。
    /// - Parameters:
    ///   - server: 目标服务器配置。
    ///   - password: 密码认证凭据（密码登录时使用）。
    ///   - keychainService: 用于读取私钥与口令的安全存储服务。
    ///   - userTier: 用户订阅层级（"free" / "paid"），free tier 限制同时只能连接 1 个服务器。
    /// - Throws: 凭据缺失、凭据读取失败、连接限制或底层连接失败时抛出。
    func ensureConnected(to server: Server, password: String?, keychainService: KeychainServiceProtocol, userTier: String = "free") async throws {
        // 连接限制：free tier 只允许同时连接 1 个服务器
        if userTier != "paid" {
            let otherActiveIDs = activeConnectionIDs.subtracting([server.id])
            if !otherActiveIDs.isEmpty {
                throw SSHError.connectionLimitReached
            }
        }

        // 快速路径
        if let client = clients[server.id], await client.isConnected {
            activeConnectionIDs.insert(server.id)
            return
        }

        let lock = lockForServer(server.id)
        try await lock.lock()
        defer { lock.unlock() }

        // double-check
        if let client = clients[server.id], await client.isConnected {
            activeConnectionIDs.insert(server.id)
            return
        }

        // 清理旧连接
        if clients[server.id] != nil {
            await performDisconnect(from: server.id)
        }

        try await connect(to: server, password: password, keychainService: keychainService)
    }

    /// 为指定服务器建立 SSH 连接并登记运行时状态。
    /// - Parameters:
    ///   - server: 目标服务器配置。
    ///   - password: 密码认证凭据（密码登录时使用）。
    ///   - keychainService: 用于读取私钥与口令的安全存储服务。
    /// - Throws: 凭据缺失、凭据读取失败或底层连接失败时抛出。
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
        await client.setServerID(server.id)
        await client.setOnDisconnected { [weak self] serverID in
            Task { @MainActor [weak self] in
                self?.handleKeepAliveDisconnection(serverID: serverID)
            }
        }
        try await client.connect(to: server, password: password, sshKeyData: sshKeyData, keyPassphrase: keyPassphrase)
        clients[server.id] = client
        activeConnectionIDs.insert(server.id)
        connectionStartTimes_[server.id] = Date()

        // 缓存连接参数以供重连使用
        lastConnectionParams[server.id] = LastConnectionParams(
            server: server,
            password: password,
            keychainService: keychainService
        )

        // 快速探测 OS 与包管理器（同步，<200ms），立即可用
        await detectQuickProfile(for: server.id, client: client)

        // ACP 代理探测放后台异步执行，不阻塞连接返回
        Task { @MainActor [weak self] in
            await self?.detectAgentsInBackground(for: server.id, client: client)
        }
    }

    /// 获取已连接服务器的名称映射（用于 Live Activity 等场景）。
    func connectedServerNames() -> [UUID: String] {
        var result: [UUID: String] = [:]
        for id in activeConnectionIDs {
            if let params = lastConnectionParams[id] {
                result[id] = params.server.name
            }
        }
        return result
    }

    /// 获取已连接服务器的连接建立时间。
    func connectionStartTimes() -> [UUID: Date] {
        var result: [UUID: Date] = [:]
        for id in activeConnectionIDs {
            if let time = connectionStartTimes_[id] {
                result[id] = time
            }
        }
        return result
    }

    /// 公开 API：加锁后断连。锁获取失败 → 直接返回，不做无锁清理。
    func disconnect(from serverID: UUID) async {
        let lock = lockForServer(serverID)
        do {
            try await lock.lock()
        } catch {
            // poisoned/cancelled → 不执行无锁清理（避免与 ensureConnected 交错）。
            return
        }
        defer { lock.unlock() }
        await performDisconnect(from: serverID)
    }

    /// 内部：实际断连逻辑（不加锁，由调用方持锁）。
    private func performDisconnect(from serverID: UUID) async {
        if let client = clients[serverID] {
            await client.disconnect()
            clients.removeValue(forKey: serverID)
        }
        activeConnectionIDs.remove(serverID)
        connectionStartTimes_.removeValue(forKey: serverID)
        lastConnectionParams.removeValue(forKey: serverID)
        detectedOS.removeValue(forKey: serverID)
        detectedCapabilities.removeValue(forKey: serverID)
    }

    /// 断开全部 SSH 连接 — 逐服务器走 disconnect(from:)（内部加锁）。
    func disconnectAll() async {
        let serverIDs = Array(clients.keys)
        for serverID in serverIDs {
            await disconnect(from: serverID)
        }
        // 注意：不做 serverLocks.removeAll()。
        // 若有 in-flight 的 ensureConnected 还在等锁，清空字典会降低串行保证。
        // 锁实例是轻量对象，保留无性能影响。App 退出时自然回收。
    }

    /// 获取指定服务器对应的客户端实例。
    func getClient(for serverID: UUID) -> NIOSSHClient? {
        return clients[serverID]
    }

    /// 检查指定服务器是否有活跃的 SSH 连接。
    func isConnected(serverID: UUID) async -> Bool {
        guard let client = clients[serverID] else { return false }
        return await client.isConnected
    }

    /// 主动探测所有已断开的服务器 ID（发送轻量命令验证连接存活，无清理副作用）。
    func findDisconnectedServers() async -> [UUID] {
        let snapshot = clients
        return await withTaskGroup(of: UUID?.self, returning: [UUID].self) { group in
            for (serverID, client) in snapshot {
                group.addTask {
                    // 不能只读 isConnected flag —— 后台挂起期间 keep-alive 冻结，flag 不会更新。
                    // 必须主动发命令探测连接是否真正存活。
                    let alive: Bool
                    do {
                        _ = try await client.execute(command: "echo __probe__", timeout: 5)
                        alive = true
                    } catch {
                        alive = false
                    }
                    return alive ? nil : serverID
                }
            }

            var deadIDs: [UUID] = []
            for await disconnectedID in group {
                if let disconnectedID {
                    deadIDs.append(disconnectedID)
                }
            }
            return deadIDs
        }
    }

    // MARK: - OS 查询

    /// 获取指定服务器检测到的操作系统名称。
    func getDetectedOS(for serverID: UUID) -> String {
        return detectedOS[serverID] ?? "Linux"
    }

    // MARK: - 能力探测

    /// 快速探测 OS 与包管理器（同步执行，<200ms），连接时立即调用。
    private func detectQuickProfile(for serverID: UUID, client: NIOSSHClient) async {
        guard let store else { return }

        // OS 信息
        var osInfo = "unknown"
        do {
            let detailed = try await client.execute(
                command: "uname -a 2>/dev/null; cat /etc/os-release 2>/dev/null || sw_vers 2>/dev/null || true"
            )
            let trimmed = detailed.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                osInfo = trimmed
                let shortOS = trimmed.components(separatedBy: " ").first ?? "unknown"
                if !shortOS.isEmpty {
                    detectedOS[serverID] = shortOS
                }
            }
        } catch {
            // 探测失败时 osInfo 保持 "unknown"
        }

        // 包管理器
        let packageManager = await PackageManagerDetector.detect(
            using: { command in try await client.execute(command: command) }
        )

        // 先保存不含工具列表的 profile（后台探测完成后会追加）
        let profile = SystemProfile(
            serverID: serverID,
            detectedAt: Date(),
            osInfo: osInfo,
            packageManager: packageManager,
            installedTools: []
        )

        do {
            try await store.upsertSystemProfile(profile)
        } catch {
            print("[SystemProfile] Failed to save quick profile for server=\(serverID): \(error)")
        }
    }

    /// 后台探测 ACP 代理安装状态，完成后更新 profile 与运行时能力。
    private func detectAgentsInBackground(for serverID: UUID, client: NIOSSHClient) async {
        guard let store else { return }

        let agentNames = SystemProfile.agentToolNames
        var tools: [SystemProfile.ToolInfo] = []

        do {
            // SSH exec channel 是 non-login non-interactive shell，需 source 用户配置补全 PATH
            let checkScript = agentNames.map { name in
                """
                if command -v \(name) >/dev/null 2>&1; then \
                ver=$(\(name) --version 2>&1 | head -1); \
                echo "TOOL:\(name):$(command -v \(name)):$ver"; \
                else echo "TOOL:\(name):NOT_FOUND:"; fi
                """
            }.joined(separator: "; ")

            let fullScript = Self.shellInitPrefix + checkScript
            let output = try await client.execute(command: fullScript)
            for line in output.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.hasPrefix("TOOL:") else { continue }
                let parts = trimmed.dropFirst(5).components(separatedBy: ":")
                guard parts.count >= 2 else { continue }
                let name = parts[0]
                let pathOrNotFound = parts[1]
                let available = pathOrNotFound != "NOT_FOUND"
                let version: String?
                if available, parts.count >= 3 {
                    let ver = parts[2...].joined(separator: ":").trimmingCharacters(in: .whitespacesAndNewlines)
                    version = ver.isEmpty ? nil : ver
                } else {
                    version = nil
                }
                tools.append(SystemProfile.ToolInfo(
                    name: name,
                    available: available,
                    version: version,
                    path: available ? pathOrNotFound : nil
                ))
            }
        } catch {
            // 探测失败时 tools 为空
        }

        // 补齐未出现的 agent 为不可用
        let detectedNames = Set(tools.map(\.name))
        for name in agentNames where !detectedNames.contains(name) {
            tools.append(SystemProfile.ToolInfo(name: name, available: false, version: nil, path: nil))
        }

        // 合并到已有 profile（保留 OS 和包管理器信息）
        if let existing = try? await store.fetchSystemProfile(forServer: serverID) {
            let updated = SystemProfile(
                serverID: serverID,
                detectedAt: Date(),
                osInfo: existing.osInfo,
                packageManager: existing.packageManager,
                installedTools: tools
            )
            try? await store.upsertSystemProfile(updated)
            let caps = updated.toCapabilities()
            detectedCapabilities[serverID] = caps
            await client.setCapabilities(caps)
        }
    }

    /// 从 SwiftData 获取指定服务器的系统环境探测结果。
    func fetchSystemProfile(for serverID: UUID) async -> SystemProfile? {
        guard let store else { return nil }
        return try? await store.fetchSystemProfile(forServer: serverID)
    }

    /// 重新探测并更新系统环境信息（对话结束后有写操作时调用）。
    /// 只刷新 ACP 代理状态，通用工具不再探测。
    func refreshSystemProfile(for serverID: UUID) async {
        guard let client = clients[serverID] else { return }
        await detectAgentsInBackground(for: serverID, client: client)
    }

    /// 获取指定服务器探测到的能力。
    func getCapabilities(for serverID: UUID) -> ServerCapabilities {
        detectedCapabilities[serverID] ?? .unknown
    }

    /// 重新探测指定服务器的能力（如安装适配器后刷新）。
    func refreshCapabilities(for serverID: UUID) async {
        guard let client = clients[serverID] else { return }
        await detectAgentsInBackground(for: serverID, client: client)
    }

    // MARK: - Keepalive 断线处理

    /// Keepalive 检测到断线时立即更新 UI 状态（移除绿色光晕），不做清理或重连。
    /// 清理由后续的 health check（ChatView 内）或 findDisconnectedServers（前台恢复）负责。
    private func handleKeepAliveDisconnection(serverID: UUID) {
        activeConnectionIDs.remove(serverID)

        // 触发退避重连（后台 Task）
        if let params = lastConnectionParams[serverID] {
            Task { [weak self] in
                await self?.reconnectWithBackoff(server: params.server, keychainService: params.keychainService)
            }
        }
    }

    // MARK: - 自动重连

    /// 检查指定服务器连接是否存活，若已断开则尝试自动重连。
    /// 加锁保证与 ensureConnected / disconnect 互斥，避免并发创建多个客户端实例。
    func checkAndReconnect(server: Server, password: String? = nil, keychainService: KeychainServiceProtocol? = nil) async {
        let serverID = server.id

        if let client = clients[serverID], await client.isConnected {
            activeConnectionIDs.insert(serverID)
            return
        }

        // 尝试从缓存或传入参数中获取重连所需信息
        let params: LastConnectionParams?
        if let keychainService {
            params = LastConnectionParams(server: server, password: password, keychainService: keychainService)
        } else {
            params = lastConnectionParams[serverID]
        }

        guard let reconnectParams = params else {
            return
        }

        // 获取 per-server 锁，与 ensureConnected / disconnect 互斥
        let lock = lockForServer(serverID)
        do {
            try await lock.lock()
        } catch {
            // poisoned/cancelled → 不执行无锁操作
            return
        }
        defer { lock.unlock() }

        // double-check：拿到锁后连接可能已被其他路径恢复
        if let client = clients[serverID], await client.isConnected {
            activeConnectionIDs.insert(serverID)
            return
        }

        // 通过 performDisconnect 完整清理旧连接（含 shell channel、PTY、activeConnectionIDs 等）
        await performDisconnect(from: serverID)

        do {
            try await connect(
                to: reconnectParams.server,
                password: reconnectParams.password,
                keychainService: reconnectParams.keychainService
            )
        } catch {
            // performDisconnect 已清理旧状态；失败后保持断开即可
        }
    }

    // MARK: - 退避重连

    /// 带指数退避的自动重连。每次重试独立获取/释放锁，sleep 期间不持锁。
    /// - Returns: 是否成功重连。
    @discardableResult
    func reconnectWithBackoff(server: Server, password: String? = nil, keychainService: KeychainServiceProtocol? = nil) async -> Bool {
        let serverID = server.id

        // 防止并发重连循环
        guard isReconnecting[serverID] != true else { return false }
        isReconnecting[serverID] = true
        defer {
            isReconnecting[serverID] = nil
            reconnectProgress[serverID] = nil
        }

        let params: LastConnectionParams?
        if let keychainService {
            params = LastConnectionParams(server: server, password: password, keychainService: keychainService)
        } else {
            params = lastConnectionParams[serverID]
        }
        guard let reconnectParams = params else { return false }

        for attempt in 0..<reconnectPolicy.maxAttempts {
            guard !Task.isCancelled else { break }
            // 外部调用 clearReconnectState 时 isReconnecting 被置 nil，表示应中止退避循环
            guard isReconnecting[serverID] == true else { break }

            reconnectProgress[serverID] = (attempt: attempt + 1, maxAttempts: reconnectPolicy.maxAttempts)

            // 每次重试独立获取锁
            let lock = lockForServer(serverID)
            do {
                try await lock.lock()
            } catch {
                break
            }

            // double-check
            if let client = clients[serverID], await client.isConnected {
                lock.unlock()
                activeConnectionIDs.insert(serverID)
                return true
            }

            await performDisconnect(from: serverID)

            var success = false
            do {
                try await connect(
                    to: reconnectParams.server,
                    password: reconnectParams.password,
                    keychainService: reconnectParams.keychainService
                )
                success = true
            } catch {
                // 本次尝试失败
            }

            lock.unlock()

            if success { return true }

            // sleep 在锁外
            guard !Task.isCancelled, isReconnecting[serverID] == true else { break }
            if attempt < reconnectPolicy.maxAttempts - 1 {
                try? await Task.sleep(for: .seconds(reconnectPolicy.delay(forAttempt: attempt)))
            }
        }
        return false
    }

    /// 清除指定服务器的重连状态（用于手动断开或删除服务器）。
    func clearReconnectState(for serverID: UUID) {
        isReconnecting[serverID] = nil
        reconnectProgress[serverID] = nil
    }

    // MARK: - 目录探测

    /// 列出远端目录下的子目录名（用于目录浏览器）。
    func listDirectory(path: String, serverID: UUID) async throws -> [String] {
        guard let client = getClient(for: serverID) else { return [] }
        let escapedPath = "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let rawOutput = try await client.execute(
            command: "ls -1 -p \(escapedPath) 2>/dev/null | grep '/$' | sed 's/\\/$//' | head -50"
        )
        return rawOutput.strippingANSIEscapes()
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// 解析远端用户主目录路径。
    func resolveHomeDirectory(serverID: UUID) async throws -> String {
        guard let client = getClient(for: serverID) else { return "/" }
        let rawOutput = try await client.execute(command: "echo $HOME")
        let home = rawOutput.strippingANSIEscapes().trimmingCharacters(in: .whitespacesAndNewlines)
        return home.isEmpty ? "/" : home
    }
}

#if DEBUG
extension SSHSessionManager {
    /// 测试注入：向会话管理器注册一个客户端，避免测试依赖真实网络连接。
    /// 仅用于单元测试构造可控场景。
    func registerClientForTesting(serverID: UUID, client: NIOSSHClient) {
        clients[serverID] = client
    }

    /// 测试辅助：手动设置重连进度。
    func setReconnectProgressForTesting(serverID: UUID, attempt: Int, maxAttempts: Int) {
        reconnectProgress[serverID] = (attempt: attempt, maxAttempts: maxAttempts)
    }
}
#endif
