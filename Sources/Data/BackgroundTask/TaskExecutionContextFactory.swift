/// 文件说明：TaskExecutionContextFactory，封装任务执行所需的上下文构建与工具注册表组装。
import Foundation

/// TaskExecutionContextFactory：
/// 封装服务器上下文构建、工具注册表组装、权限解析逻辑，
/// 供 TaskExecutionCoordinator 使用。
@MainActor
struct TaskExecutionContextFactory {

    // MARK: - Dependencies

    private let sshManager: SSHSessionManager
    private let toolRegistry: ToolRegistryProtocol
    private let memoryContextProvider: MemoryContextProvider
    private let authService: AuthServiceProtocol
    private let memoryService: MemoryService?
    private let store: SwiftDataStore

    /// Relay 模式下注册的 RelaySSHClient（keyed by serverID）。
    private var relayClients: [UUID: RelaySSHClient] = [:]

    init(
        sshManager: SSHSessionManager,
        toolRegistry: ToolRegistryProtocol,
        memoryContextProvider: MemoryContextProvider,
        authService: AuthServiceProtocol,
        memoryService: MemoryService?,
        store: SwiftDataStore
    ) {
        self.sshManager = sshManager
        self.toolRegistry = toolRegistry
        self.memoryContextProvider = memoryContextProvider
        self.authService = authService
        self.memoryService = memoryService
        self.store = store
    }

    // MARK: - Relay Client Management

    /// 注册 Relay SSH 客户端（瘦 Relay 模式替代 NIOSSHClient）。
    mutating func registerRelayClient(_ client: RelaySSHClient, for serverID: UUID) {
        relayClients[serverID] = client
    }

    /// 移除 Relay SSH 客户端。
    mutating func removeRelayClient(for serverID: UUID) {
        relayClients.removeValue(forKey: serverID)
    }

    /// 获取指定服务器的 SSH 客户端（优先 Relay，回退 NIO）。
    func getClient(for serverID: UUID) -> (any SSHClientProtocol)? {
        if let relayClient = relayClients[serverID] {
            return relayClient
        }
        return sshManager.getClient(for: serverID)
    }

    // MARK: - Context Construction

    /// 构建服务器上下文字符串，包含基础信息、系统 profile 和记忆上下文。
    func buildServerContext(serverID: UUID, server: Server, userInput: String) async -> String {
        let detectedOS = sshManager.getDetectedOS(for: serverID)
        let userName = authService.currentUser?.displayName
        let userClause = userName.map { ", UserName: \($0)" } ?? ""
        var baseServerContext = "ServerName: \(server.name), Host: \(server.host), User: \(server.username), OS: \(detectedOS)\(userClause)"

        // 系统 profile
        let profile = try? await store.fetchSystemProfile(forServer: serverID)
        if let profile {
            baseServerContext += "\n\n" + profile.formattedContext()
        }

        // 记忆上下文
        let memoryBlock = await memoryContextProvider.buildMemoryContext(serverID: serverID, userInput: userInput)
        return memoryBlock.isEmpty
            ? baseServerContext
            : baseServerContext + "\n\n" + memoryBlock
    }

    // MARK: - Tool Registry

    /// 构建任务级工具注册表，按需注入记忆读写工具。
    /// Relay 模式下排除 UploadFileTool（文件上传需 SSH SFTP 通道，Relay 不支持）。
    func makeTaskToolRegistry(serverID: UUID) -> ToolRegistryProtocol {
        let isRelay = relayClients[serverID] != nil
        let filteredBaseTools = isRelay
            ? toolRegistry.tools.filter { $0.name != "upload_file" }
            : toolRegistry.tools
        return ToolRegistryFactory.makeTaskRegistry(
            baseTools: filteredBaseTools,
            serverID: serverID,
            memoryService: memoryService
        )
    }

    // MARK: - Permission Resolution

    /// 解析有效权限等级（服务器级 > 全局默认）。
    nonisolated func resolvePermissionLevel(server: Server) -> PermissionLevel {
        let globalPermissionLevel = AISettings.load().permissionLevel
        return server.permissionLevel.resolved(globalLevel: globalPermissionLevel)
    }

    // MARK: - SSH Client

    /// 获取指定服务器的 SSH 客户端。
    func getSSHClient(for serverID: UUID) -> NIOSSHClient? {
        sshManager.getClient(for: serverID)
    }

    /// 获取 SSHSessionManager 引用（供任务后处理使用）。
    var sshSessionManager: SSHSessionManager { sshManager }
}
