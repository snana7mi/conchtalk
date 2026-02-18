import SwiftUI

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

    private func loadConversations() async {
        isLoading = true
        do {
            conversations = try await store.fetchConversations(forServer: server.id)
        } catch {
            conversations = []
        }
        isLoading = false
    }

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
