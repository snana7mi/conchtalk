/// 文件说明：ChatView，负责聊天模块的界面展示与交互流程。
import SwiftUI

/// ChatView：负责界面渲染与用户交互响应。
struct ChatView: View {
    @State var viewModel: ChatViewModel

    /// 是否正在尝试自动重连。
    @State private var isReconnecting = false

    /// 标记是否曾经成功连接过（用于区分初始连接失败与断线）。
    @State private var hasConnectedBefore = false

    /// 健康检查任务是否处于活跃状态。
    @State private var healthCheckActive = false

    var body: some View {
        VStack(spacing: 0) {
            // 连接状态横幅
            connectionBanner

            // Messages
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: Theme.messageSpacing) {
                        ForEach(viewModel.messages) { message in
                            // Show persisted thinking bubble before command/assistant messages that have reasoning
                            if !message.isLoading,
                               let reasoning = message.reasoningContent, !reasoning.isEmpty {
                                HStack {
                                    ThinkingBubbleView(
                                        reasoningContent: reasoning,
                                        isLiveStreaming: false
                                    )
                                    Spacer(minLength: 60)
                                }
                            }

                            // Show live streaming thinking bubble before the loading indicator
                            if message.isLoading
                                && viewModel.isProcessing
                                && !viewModel.activeReasoningText.isEmpty {
                                HStack {
                                    ThinkingBubbleView(
                                        reasoningContent: viewModel.activeReasoningText,
                                        isLiveStreaming: viewModel.isReasoningActive
                                    )
                                    Spacer(minLength: 60)
                                }
                                .id(viewModel.thinkingBubbleId)
                            }

                            if message.isLoading {
                                MessageBubbleView(
                                    message: message,
                                    liveContentText: viewModel.activeContentText.isEmpty ? nil : viewModel.activeContentText,
                                    liveToolOutput: viewModel.liveToolOutput.isEmpty ? nil : viewModel.liveToolOutput
                                )
                                .id(message.id)
                            } else {
                                MessageBubbleView(message: message)
                                    .id(message.id)
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
                .onChange(of: viewModel.liveToolOutput) {
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
                            hasConnectedBefore = false
                        } else {
                            await viewModel.connect()
                            if viewModel.isConnected {
                                hasConnectedBefore = true
                            }
                        }
                    }
                } label: {
                    connectionToolbarIcon
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
            if viewModel.isConnected {
                hasConnectedBefore = true
            }
            healthCheckActive = true
        }
        .task(id: healthCheckActive) {
            guard healthCheckActive else { return }
            await runHealthCheck()
        }
    }

    // MARK: - 连接状态横幅

    /// 根据连接状态展示断线或重连中的提示横幅。
    @ViewBuilder
    private var connectionBanner: some View {
        if isReconnecting {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.mini)
                Text("正在重连…")
                    .font(.caption)
                Spacer()
            }
            .padding(.horizontal, Theme.screenPadding)
            .padding(.vertical, 6)
            .background(Color.orange.opacity(0.12))
            .foregroundStyle(.orange)
            .transition(.move(edge: .top).combined(with: .opacity))
        } else if !viewModel.isConnected && hasConnectedBefore {
            HStack(spacing: 6) {
                Image(systemName: "wifi.slash")
                    .font(.caption)
                Text("连接已断开")
                    .font(.caption)
                Spacer()
                Button {
                    Task { await attemptReconnect() }
                } label: {
                    Text("重新连接")
                        .font(.caption)
                        .fontWeight(.medium)
                }
            }
            .padding(.horizontal, Theme.screenPadding)
            .padding(.vertical, 6)
            .background(Color.red.opacity(0.12))
            .foregroundStyle(.red)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    // MARK: - 工具栏连接图标

    /// 根据连接状态显示不同颜色的闪电图标。
    private var connectionToolbarIcon: some View {
        Group {
            if isReconnecting {
                Image(systemName: "bolt.trianglebadge.exclamationmark")
                    .foregroundStyle(.orange)
            } else if viewModel.isConnected {
                Image(systemName: "bolt.fill")
                    .foregroundStyle(.green)
            } else {
                Image(systemName: "bolt.slash")
                    .foregroundStyle(.red)
            }
        }
    }

    // MARK: - 自动重连

    /// 尝试重新建立连接。
    private func attemptReconnect() async {
        guard !isReconnecting else { return }
        withAnimation { isReconnecting = true }
        await viewModel.connect()
        withAnimation { isReconnecting = false }
        if viewModel.isConnected {
            hasConnectedBefore = true
        }
    }

    // MARK: - 健康检查

    /// 每 60 秒轮询一次连接状态，断开时自动尝试重连。
    private func runHealthCheck() async {
        while !Task.isCancelled && healthCheckActive {
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled && healthCheckActive else { break }

            // 仅在本地标记「已连接」时检查底层真实状态
            if viewModel.isConnected {
                let reallyConnected = await viewModel.checkConnectionAlive()
                if !reallyConnected {
                    // 底层已断开，更新本地状态并尝试重连
                    await attemptReconnect()
                }
            }
        }
    }

    // MARK: - 确认弹窗文案

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
        case "sftp_write_file":
            let path = args?["path"] as? String ?? ""
            return "\(toolCall.explanation)\n\nWrite to: \(path)"
        case "manage_service":
            let service = args?["service"] as? String ?? ""
            let action = args?["action"] as? String ?? ""
            return "\(toolCall.explanation)\n\nsystemctl \(action) \(service)"
        default:
            return toolCall.explanation
        }
    }
}
