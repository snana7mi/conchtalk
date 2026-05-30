/// 文件说明：ServerListView，负责服务器列表与分组管理界面。
import SwiftUI

/// ServerListView：负责界面渲染与用户交互响应。
struct ServerListView: View {
    @State var viewModel: ServerListViewModel
    @State private var editingServer: Server?
    @State private var sshKeys: [SSHKey] = []
    let sshManager: SSHSessionManager
    let keychainService: any KeychainServiceProtocol
    let onSelectServer: (Server) -> Void
    var onDisconnect: ((UUID) -> Void)?

    var body: some View {
        List {
            if viewModel.isSearching {
                // 搜索结果：按名称/主机名匹配的服务器列表
                ForEach(viewModel.searchResults) { server in
                    Button {
                        onSelectServer(server)
                    } label: {
                        ServerRowView(server: server)
                    }
                }
            } else if viewModel.servers.isEmpty && !viewModel.isLoading {
                ContentUnavailableView {
                    Label(String(localized: "No Servers", bundle: LanguageSettings.currentBundle), systemImage: "server.rack")
                } description: {
                    Text(String(localized: "Add a server to get started", bundle: LanguageSettings.currentBundle))
                } actions: {
                    Button(String(localized: "Add Server", bundle: LanguageSettings.currentBundle)) {
                        viewModel.showAddServer = true
                    }
                }
            } else {
                ForEach(Array(viewModel.groupedServers.enumerated()), id: \.offset) { _, entry in
                    Section(entry.group?.name ?? String(localized: "Ungrouped", bundle: LanguageSettings.currentBundle)) {
                        ForEach(entry.servers) { server in
                            let isSSHConnected = sshManager.activeConnectionIDs.contains(server.id)
                            Button {
                                onSelectServer(server)
                            } label: {
                                ServerRowView(server: server)
                            }
                            .modifier(GlowBorderModifier(isActive: isSSHConnected))
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    Task { await viewModel.deleteServer(server) }
                                } label: {
                                    Label(String(localized: "Delete", bundle: LanguageSettings.currentBundle), systemImage: "trash")
                                }
                                Button {
                                    editingServer = server
                                } label: {
                                    Label(String(localized: "Edit", bundle: LanguageSettings.currentBundle), systemImage: "pencil")
                                }
                                .tint(.blue)
                            }
                            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                if isSSHConnected {
                                    Button {
                                        onDisconnect?(server.id)
                                    } label: {
                                        Label(String(localized: "Disconnect", bundle: LanguageSettings.currentBundle), systemImage: "bolt.slash")
                                    }
                                    .tint(.red)
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("ConchTalk")
        .searchable(text: $viewModel.searchText, prompt: String(localized: "Search conversations", bundle: LanguageSettings.currentBundle))
        .onChange(of: viewModel.searchText) {
            Task { await viewModel.search() }
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Menu {
                    Button {
                        viewModel.showAddServer = true
                    } label: {
                        Label(String(localized: "Add Server", bundle: LanguageSettings.currentBundle), systemImage: "plus")
                    }
                    Button {
                        viewModel.showManageGroups = true
                    } label: {
                        Label(String(localized: "Manage Groups", bundle: LanguageSettings.currentBundle), systemImage: "folder")
                    }
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $viewModel.showAddServer) {
            AddServerView(groups: viewModel.groups, availableKeys: sshKeys, keychainService: keychainService) { server, password, groupID in
                Task { await viewModel.addServer(server, password: password, groupID: groupID) }
            }
        }
        .sheet(isPresented: $viewModel.showManageGroups) {
            ManageGroupsView(
                groups: $viewModel.groups,
                onAdd: { name in await viewModel.addGroup(name) },
                onDelete: { id in await viewModel.deleteGroup(id) }
            )
        }
        .sheet(item: $editingServer) { server in
            AddServerView(editing: server, groups: viewModel.groups, availableKeys: sshKeys, keychainService: keychainService) { updated, password, groupID in
                Task { await viewModel.updateServer(updated, password: password, groupID: groupID) }
            }
        }
        .task {
            await viewModel.loadServers()
            sshKeys = (try? await viewModel.fetchSSHKeys()) ?? []
        }
        .onReceive(NotificationCenter.default.publisher(for: .syncDidPullNewData)) { _ in
            Task { await viewModel.loadServers() }
        }
        .onChange(of: viewModel.showAddServer) {
            if viewModel.showAddServer {
                Task { sshKeys = (try? await viewModel.fetchSSHKeys()) ?? [] }
            }
        }
        .onChange(of: editingServer) {
            if editingServer != nil {
                Task { sshKeys = (try? await viewModel.fetchSSHKeys()) ?? [] }
            }
        }
    }
}

/// ServerRowView：负责界面渲染与用户交互响应。
struct ServerRowView: View {
    let server: Server

    @ViewBuilder
    private var serverIcon: some View {
        if let data = FlagImageRenderer.resolveServerIconData(server: server, size: 80),
           let img = ImageUtils.makeSwiftUIImage(from: data) {
            img
                .resizable()
                .scaledToFill()
        } else {
            Text(server.flagEmoji)
                .font(.title)
                .background(Color.secondary.opacity(0.1))
        }
    }

    /// 计算剩余天数，nil 表示无期限。
    private var remainingDays: Int? {
        guard let expDate = server.expirationDate else { return nil }
        let days = Calendar.current.dateComponents([.day], from: Date(), to: expDate).day ?? 0
        return max(0, days)
    }

    /// 根据剩余天数返回对应颜色。
    private var expirationColor: Color {
        guard let days = remainingDays else { return .clear }
        if days < 3 { return .red }
        if days < 30 { return .yellow }
        return .green
    }

    var body: some View {
        HStack(spacing: 12) {
            serverIcon
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(server.name)
                    .font(.headline)

                Text("\(server.username)@\(server.host):\(server.port)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let days = remainingDays {
                Text("\(days)d")
                    .font(.caption2.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(expirationColor, in: Capsule())
            }

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.quaternary)
        }
        .padding(.vertical, 4)
    }
}
