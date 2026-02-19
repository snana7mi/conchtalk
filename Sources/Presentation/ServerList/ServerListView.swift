/// 文件说明：ServerListView，负责服务器列表与分组管理界面。
import SwiftUI

/// ServerListView：负责界面渲染与用户交互响应。
struct ServerListView: View {
    @State var viewModel: ServerListViewModel
    @State private var editingServer: Server?
    let onSelectServer: (Server) -> Void
    var onSelectConversation: ((ConversationSearchResult) -> Void)?

    var body: some View {
        List {
            if viewModel.isSearching {
                // Search results
                ForEach(viewModel.searchResults) { result in
                    Button {
                        onSelectConversation?(result)
                    } label: {
                        SearchResultRow(result: result)
                    }
                }
            } else if viewModel.servers.isEmpty && !viewModel.isLoading {
                ContentUnavailableView {
                    Label("No Servers", systemImage: "server.rack")
                } description: {
                    Text("Add a server to get started")
                } actions: {
                    Button("Add Server") {
                        viewModel.showAddServer = true
                    }
                }
            } else {
                ForEach(Array(viewModel.groupedServers.enumerated()), id: \.offset) { _, entry in
                    Section(entry.group?.name ?? String(localized: "Ungrouped")) {
                        ForEach(entry.servers) { server in
                            Button {
                                onSelectServer(server)
                            } label: {
                                ServerRowView(server: server)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    Task { await viewModel.deleteServer(server) }
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                Button {
                                    editingServer = server
                                } label: {
                                    Label("Edit", systemImage: "pencil")
                                }
                                .tint(.blue)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("ConchTalk")
        .searchable(text: $viewModel.searchText, prompt: "Search conversations")
        .onChange(of: viewModel.searchText) {
            Task { await viewModel.search() }
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Menu {
                    Button {
                        viewModel.showAddServer = true
                    } label: {
                        Label("Add Server", systemImage: "plus")
                    }
                    Button {
                        viewModel.showManageGroups = true
                    } label: {
                        Label("Manage Groups", systemImage: "folder")
                    }
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $viewModel.showAddServer) {
            AddServerView(groups: viewModel.groups) { server, password, groupID in
                Task { await viewModel.addServer(server, password: password, groupID: groupID) }
            }
        }
        .sheet(isPresented: $viewModel.showManageGroups) {
            ManageGroupsView(
                groups: viewModel.groups,
                onAdd: { name in await viewModel.addGroup(name) },
                onDelete: { id in await viewModel.deleteGroup(id) }
            )
        }
        .sheet(item: $editingServer) { server in
            AddServerView(editing: server, groups: viewModel.groups) { updated, password, groupID in
                Task { await viewModel.updateServer(updated, password: password, groupID: groupID) }
            }
        }
        .task {
            await viewModel.loadServers()
        }
    }
}

/// SearchResultRow：UI 层组件，承载展示与交互职责。
private struct SearchResultRow: View {
    let result: ConversationSearchResult

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(result.conversationTitle)
                .font(.headline)
            Text(result.serverName)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(result.matchingSnippet)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(2)
        }
        .padding(.vertical, 2)
    }
}

/// ServerRowView：负责界面渲染与用户交互响应。
struct ServerRowView: View {
    let server: Server

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "server.rack")
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 40, height: 40)
                .background(Color.secondary.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(server.name)
                    .font(.headline)

                Text("\(server.username)@\(server.host):\(server.port)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.quaternary)
        }
        .padding(.vertical, 4)
    }
}
