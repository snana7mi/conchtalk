import SwiftUI
import SwiftData

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

    init(store: SwiftDataStore) {
        self.store = store
    }

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

    func deleteServer(_ server: Server) async {
        do {
            try await store.deleteServer(server.id)
            servers.removeAll { $0.id == server.id }
            groupedServers = try await store.fetchServersGrouped()
        } catch {
            self.error = error.localizedDescription
        }
    }

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
