/// 文件说明：ServerListViewModel，负责服务器列表与分组管理界面。
import SwiftUI
import SwiftData

/// ServerListViewModel：管理界面状态，并协调交互与业务调用。
@Observable
final class ServerListViewModel {
    var servers: [Server] = []
    var groupedServers: [(group: ServerGroup?, servers: [Server])] = []
    var groups: [ServerGroup] = []
    var isLoading = false
    var error: String?
    var showAddServer = false
    var showManageGroups = false

    // Search
    var searchText: String = ""
    /// 搜索结果：按名称/主机名筛选的服务器列表。
    var searchResults: [Server] = []
    var isSearching: Bool { !searchText.isEmpty }

    private let store: SwiftDataStore
    private let keychainService: any KeychainServiceProtocol

    /// 初始化视图模型，并注入所需业务依赖。
    init(store: SwiftDataStore, keychainService: any KeychainServiceProtocol) {
        self.store = store
        self.keychainService = keychainService
    }

    /// loadServers：加载并同步当前场景所需数据。
    func loadServers() async {
        isLoading = true
        do {
            servers = try await store.fetchServers()
            groupedServers = try await store.fetchServersGrouped()
            groups = try await store.fetchGroups()

            // 为缺少国家代码的公网服务器补充查询（仅一次，结果持久化后不再重复）
            let missing = servers.filter { $0.countryCode == nil }
            if !missing.isEmpty {
                var changed = false
                for server in missing {
                    // lookupCountryCode 内部走同步阻塞的 getaddrinfo（无超时），本 VM 是 MainActor 隔离，
                    // 直接调用会卡住主线程数秒——放到后台 detached 执行，结果是 Sendable 的 String?。
                    let host = server.host
                    if let code = await Task.detached(priority: .utility, operation: { IPGeoService.lookupCountryCode(for: host) }).value {
                        var updated = server
                        updated.countryCode = code
                        try await store.updateServer(updated)
                        changed = true
                    }
                }
                if changed {
                    servers = try await store.fetchServers()
                    groupedServers = try await store.fetchServersGrouped()
                }
            }
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
        // 刷新搜索结果（servers 更新后 searchResults 需同步）
        if isSearching {
            await search()
        }
    }

    /// deleteServer：删除目标数据并维护一致性（含 Keychain 密码、主机指纹清理）。
    func deleteServer(_ server: Server) async {
        do {
            // 先清理 Keychain 中可能存在的密码，避免残留
            try keychainService.deletePassword(forServer: server.id)
            // 清理该服务器的已知主机密钥指纹
            await KnownHostsStore().remove(host: server.host, port: server.port)
            try await store.deleteServer(server.id)
            servers.removeAll { $0.id == server.id }
            groupedServers = try await store.fetchServersGrouped()
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// addServer：追加新数据并更新相关状态。
    func addServer(_ server: Server, password: String?, groupID: UUID?) async {
        do {
            // 离线查询 IP 所属国家（getaddrinfo 阻塞，放后台执行避免冻结主线程）
            var serverWithGeo = server
            let host = server.host
            serverWithGeo.countryCode = await Task.detached(priority: .utility, operation: { IPGeoService.lookupCountryCode(for: host) }).value

            try await store.saveServer(serverWithGeo)
            if let password, case .password = server.authMethod {
                try keychainService.savePassword(password, forServer: server.id)
            }
            if let groupID {
                try await store.assignServer(server.id, toGroup: groupID)
            }
            servers.insert(serverWithGeo, at: 0)
            groupedServers = try await store.fetchServersGrouped()
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// updateServer：更新状态并触发后续联动。
    func updateServer(_ server: Server, password: String?, groupID: UUID?) async {
        do {
            var serverWithGeo = server
            // 重新查询国家代码；查询失败时保留旧值（getaddrinfo 阻塞，放后台执行）
            let host = server.host
            let newCode = await Task.detached(priority: .utility, operation: { IPGeoService.lookupCountryCode(for: host) }).value
            if newCode != nil {
                serverWithGeo.countryCode = newCode
            }
            // 若旧值也没有且新查询也失败，保持 nil（显示 ❓）

            try await store.updateServer(serverWithGeo)
            if let password, case .password = server.authMethod {
                try keychainService.savePassword(password, forServer: server.id)
            }
            try await store.assignServer(server.id, toGroup: groupID)
            await loadServers()
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Group Operations

    /// addGroup：追加新数据并更新相关状态。
    func addGroup(_ name: String) async {
        let group = ServerGroup(name: name, sortOrder: groups.count)
        do {
            try await store.saveGroup(group)
            groups = try await store.fetchGroups()
            groupedServers = try await store.fetchServersGrouped()
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// deleteGroup：删除目标数据并维护一致性。
    func deleteGroup(_ groupID: UUID) async {
        do {
            try await store.deleteGroup(groupID)
            groups = try await store.fetchGroups()
            groupedServers = try await store.fetchServersGrouped()
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - SSH Keys

    /// fetchSSHKeys：获取全部 SSH 密钥供服务器配置使用。
    func fetchSSHKeys() async throws -> [SSHKey] {
        try await store.fetchSSHKeys()
    }

    // MARK: - Expiration

    /// 清理已过期的服务器，返回被删除的服务器名称列表。
    func deleteExpiredServers() async -> [String] {
        do {
            let expired = try await store.fetchExpiredServers()
            guard !expired.isEmpty else { return [] }
            var deletedNames: [String] = []
            for server in expired {
                await deleteServer(server)
                deletedNames.append(server.name)
            }
            return deletedNames
        } catch {
            self.error = error.localizedDescription
            return []
        }
    }

    // MARK: - Search

    /// search：根据关键词按服务器名/主机名过滤并更新结果。
    func search() async {
        guard !searchText.isEmpty else {
            searchResults = []
            return
        }
        let query = searchText.lowercased()
        searchResults = servers.filter {
            $0.name.lowercased().contains(query) ||
            $0.host.lowercased().contains(query) ||
            $0.username.lowercased().contains(query)
        }
    }
}
