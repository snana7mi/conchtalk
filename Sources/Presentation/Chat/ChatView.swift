import SwiftUI

struct ChatView: View {
    @State var viewModel: ChatViewModel

    var body: some View {
        VStack(spacing: 0) {
            // Messages
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: Theme.messageSpacing) {
                        ForEach(viewModel.messages) { message in
                            MessageBubbleView(message: message)
                                .id(message.id)
                        }
                    }
                    .padding(.horizontal, Theme.screenPadding)
                    .padding(.vertical, 8)
                }
                .onChange(of: viewModel.messages.count) {
                    if let lastMessage = viewModel.messages.last {
                        withAnimation(.easeOut(duration: 0.3)) {
                            proxy.scrollTo(lastMessage.id, anchor: .bottom)
                        }
                    }
                }
            }

            Divider()

            // Input bar
            ChatInputBar(
                text: $viewModel.inputText,
                isProcessing: viewModel.isProcessing,
                isConnected: viewModel.isConnected,
                onSend: {
                    Task { await viewModel.sendMessage() }
                }
            )
        }
        .navigationTitle(viewModel.serverDisplayName)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    Task {
                        if viewModel.isConnected {
                            await viewModel.disconnect()
                        } else {
                            await viewModel.connect()
                        }
                    }
                } label: {
                    Image(systemName: viewModel.isConnected ? "bolt.fill" : "bolt.slash")
                        .foregroundStyle(viewModel.isConnected ? .green : .red)
                }
            }
        }
        .alert("Confirm Command", isPresented: $viewModel.showConfirmation) {
            Button("Execute", role: .destructive) { viewModel.approveCommand() }
            Button("Cancel", role: .cancel) { viewModel.denyCommand() }
        } message: {
            if let cmd = viewModel.pendingCommand {
                Text("\(cmd.explanation)\n\n$ \(cmd.command)")
            }
        }
        .task {
            await viewModel.loadMessages()
            await viewModel.connect()
        }
    }
}
