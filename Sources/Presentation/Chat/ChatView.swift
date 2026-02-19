/// 文件说明：ChatView，负责聊天模块的界面展示与交互流程。
import SwiftUI

/// ChatView：负责界面渲染与用户交互响应。
struct ChatView: View {
    @State var viewModel: ChatViewModel

    var body: some View {
        VStack(spacing: 0) {
            // Messages
            ScrollViewReader { proxy in
                let lastUserMessageId = viewModel.messages.last(where: { $0.role == .user })?.id

                ScrollView {
                    LazyVStack(spacing: Theme.messageSpacing) {
                        ForEach(viewModel.messages) { message in
                            if message.isLoading {
                                MessageBubbleView(
                                    message: message,
                                    liveContentText: viewModel.activeContentText.isEmpty ? nil : viewModel.activeContentText
                                )
                                .id(message.id)
                            } else {
                                MessageBubbleView(message: message)
                                    .id(message.id)
                            }

                            // Show thinking bubble after each user message
                            if message.role == .user {
                                if let reasoning = reasoningAfterUserMessage(message) {
                                    // Persisted thinking bubble
                                    HStack {
                                        ThinkingBubbleView(
                                            reasoningContent: reasoning,
                                            isLiveStreaming: false
                                        )
                                        Spacer(minLength: 60)
                                    }
                                } else if message.id == lastUserMessageId
                                            && viewModel.isProcessing
                                            && !viewModel.activeReasoningText.isEmpty {
                                    // Live streaming thinking bubble
                                    HStack {
                                        ThinkingBubbleView(
                                            reasoningContent: viewModel.activeReasoningText,
                                            isLiveStreaming: viewModel.isReasoningActive
                                        )
                                        Spacer(minLength: 60)
                                    }
                                    .id(viewModel.thinkingBubbleId)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, Theme.screenPadding)
                    .padding(.vertical, 8)
                }
                .scrollDismissesKeyboard(.interactively)
                #if os(iOS)
                .onTapGesture {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                }
                #endif
                .onChange(of: viewModel.messages.count) {
                    if let lastMessage = viewModel.messages.last {
                        withAnimation(.easeOut(duration: 0.3)) {
                            proxy.scrollTo(lastMessage.id, anchor: .bottom)
                        }
                    }
                }
                .onChange(of: viewModel.activeReasoningText) {
                    if let lastMessage = viewModel.messages.last {
                        proxy.scrollTo(lastMessage.id, anchor: .bottom)
                    }
                }
                .onChange(of: viewModel.activeContentText) {
                    if let lastMessage = viewModel.messages.last {
                        proxy.scrollTo(lastMessage.id, anchor: .bottom)
                    }
                }
            }

            Divider()

            // Input bar
            ChatInputBar(
                text: $viewModel.inputText,
                isProcessing: viewModel.isProcessing,
                isConnected: viewModel.isConnected,
                contextUsagePercent: viewModel.contextUsagePercent,
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
        .alert("Confirm Action", isPresented: $viewModel.showConfirmation) {
            Button("Execute", role: .destructive) { viewModel.approveCommand() }
            Button("Cancel", role: .cancel) { viewModel.denyCommand() }
        } message: {
            if let toolCall = viewModel.pendingToolCall {
                Text(confirmationMessage(for: toolCall))
            }
        }
        .task {
            await viewModel.loadMessages()
            await viewModel.connect()
        }
    }

    /// Look ahead from a user message to find the reasoning content of the corresponding assistant response
    /// reasoningAfterUserMessage：提取某条用户消息后的推理内容。
    private func reasoningAfterUserMessage(_ userMessage: Message) -> String? {
        guard let userIndex = viewModel.messages.firstIndex(where: { $0.id == userMessage.id }) else {
            return nil
        }
        for i in (userIndex + 1)..<viewModel.messages.count {
            let msg = viewModel.messages[i]
            if msg.role == .user { break }
            if msg.role == .assistant && !msg.isLoading,
               let reasoning = msg.reasoningContent, !reasoning.isEmpty {
                return reasoning
            }
        }
        return nil
    }

    /// confirmationMessage：生成待确认工具调用的展示文案。
    private func confirmationMessage(for toolCall: ToolCall) -> String {
        let args = try? toolCall.decodedArguments()

        switch toolCall.toolName {
        case "execute_ssh_command":
            let cmd = args?["command"] as? String ?? ""
            return "\(toolCall.explanation)\n\n$ \(cmd)"
        case "write_file":
            let path = args?["path"] as? String ?? ""
            let append = args?["append"] as? Bool ?? false
            let action = append ? "Append to" : "Write to"
            return "\(toolCall.explanation)\n\n\(action): \(path)"
        case "manage_service":
            let service = args?["service"] as? String ?? ""
            let action = args?["action"] as? String ?? ""
            return "\(toolCall.explanation)\n\nsystemctl \(action) \(service)"
        default:
            return toolCall.explanation
        }
    }
}
