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
    var searchResults: [ConversationSearchResult] = []
    var isSearching: Bool { !searchText.isEmpty }

    private let store: SwiftDataStore

    /// 初始化视图模型，并注入所需业务依赖。
    init(store: SwiftDataStore) {
        self.store = store
    }

    /// loadServers：加载并同步当前场景所需数据。
    func loadServers() async {
        isLoading = true
        do {
            servers = try await store.fetchServers()
            groupedServers = try await store.fetchServersGrouped()
            groups = try await store.fetchGroups()
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    /// deleteServer：删除目标数据并维护一致性。
    func deleteServer(_ server: Server) async {
        do {
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
            try await store.saveServer(server)
            if let password, case .password = server.authMethod {
                let keychain = KeychainService()
                try keychain.savePassword(password, forServer: server.id)
            }
            if let groupID {
                try await store.assignServer(server.id, toGroup: groupID)
            }
            servers.insert(server, at: 0)
            groupedServers = try await store.fetchServersGrouped()
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// updateServer：更新状态并触发后续联动。
    func updateServer(_ server: Server, password: String?, groupID: UUID?) async {
        do {
            try await store.updateServer(server)
            if let password, case .password = server.authMethod {
                let keychain = KeychainService()
                try keychain.savePassword(password, forServer: server.id)
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

    // MARK: - Search

    /// search：根据关键词筛选并更新会话结果。
    func search() async {
        guard !searchText.isEmpty else {
            searchResults = []
            return
        }
        do {
            searchResults = try await store.searchConversations(query: searchText)
        } catch {
            self.error = error.localizedDescription
        }
    }
}
