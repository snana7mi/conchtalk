/// 文件说明：ConversationListView，负责聊天模块的界面展示与交互流程。
import SwiftUI

/// ConversationListView：负责界面渲染与用户交互响应。
struct ConversationListView: View {
    let server: Server
    let store: SwiftDataStore
    @Binding var selectedConversation: Conversation?

    @State private var conversations: [Conversation] = []
    @State private var isLoading = true

    var body: some View {
        List {
            if conversations.isEmpty && !isLoading {
                ContentUnavailableView {
                    Label("No Conversations", systemImage: "bubble.left.and.bubble.right")
                } description: {
                    Text("Start a conversation to get started")
                } actions: {
                    Button("New Conversation") {
                        Task { await createAndSelect() }
                    }
                }
            } else {
                ForEach(conversations) { conversation in
                    Button {
                        selectedConversation = conversation
                    } label: {
                        ConversationRow(conversation: conversation)
                    }
                }
                .onDelete { indexSet in
                    Task { await deleteConversations(at: indexSet) }
                }
            }
        }
        .navigationTitle("Conversations")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    Task { await createAndSelect() }
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .task {
            await loadConversations()
            // Auto-navigate if first conversation
            if conversations.isEmpty {
                await createAndSelect()
            }
        }
    }

    /// loadConversations：加载并同步当前场景所需数据。
    private func loadConversations() async {
        isLoading = true
        do {
            conversations = try await store.fetchConversations(forServer: server.id)
        } catch {
            conversations = []
        }
        isLoading = false
    }

    /// createAndSelect：创建新会话并将其设为当前选中项。
    private func createAndSelect() async {
        let conversation = Conversation(serverID: server.id)
        do {
            try await store.saveConversation(conversation)
            conversations.insert(conversation, at: 0)
            selectedConversation = conversation
        } catch {
            // Failed to create conversation
        }
    }

    /// deleteConversations：删除目标数据并维护一致性。
    private func deleteConversations(at offsets: IndexSet) async {
        for index in offsets {
            let conversation = conversations[index]
            do {
                try await store.deleteConversation(conversation.id)
            } catch {
                // Failed to delete
            }
        }
        conversations.remove(atOffsets: offsets)
    }
}

/// ConversationRow：UI 层组件，承载展示与交互职责。
private struct ConversationRow: View {
    let conversation: Conversation

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(conversation.title)
                .font(.headline)
            Text(conversation.updatedAt, style: .relative)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
