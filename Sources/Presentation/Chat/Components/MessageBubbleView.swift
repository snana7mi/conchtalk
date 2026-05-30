/// 文件说明：MessageBubbleView，负责聊天模块的界面展示与交互流程。
import SwiftUI

/// MessageBubbleView：负责界面渲染与用户交互响应。
struct MessageBubbleView: View {
    let message: Message
    var liveContentText: String? = nil
    var liveToolOutput: String? = nil
    var agentStreamEvents: [AgentStreamEvent] = []
    var isAgentExecuting: Bool = false
    var serverIconImage: Image? = nil
    var userAvatarImage: Image? = nil
    var agentType: AgentType? = nil
    var modeColors: Theme.ModeColors = Theme.normalMode
    var presentationState: DirectModePresentationState? = nil
    /// 点击服务器头像的回调
    var onServerAvatarTap: (() -> Void)? = nil
    @State private var skillLoadedVisible = false

    var body: some View {
        switch message.role {
        case .user:
            userBubble
        case .assistant:
            assistantBubble
        case .command:
            commandBubble
        case .system:
            systemBubble
        }
    }

    // MARK: - Avatar

    /// 服务器头像（图片）
    @ViewBuilder
    private var serverAvatar: some View {
        Button {
            onServerAvatarTap?()
        } label: {
            if let img = serverIconImage {
                img
                    .resizable()
                    .scaledToFill()
                    .frame(width: 40, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                Image(systemName: "server.rack")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
                    .frame(width: 40, height: 40)
                    .background(Color.secondary.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
        .buttonStyle(.plain)
    }

    /// 用户头像
    @ViewBuilder
    private var userAvatar: some View {
        if let userAvatarImage {
            userAvatarImage
                .resizable()
                .scaledToFill()
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            Image(systemName: "person.fill")
                .font(.system(size: 18))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(Color.blue)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    /// 根据消息来源选择头像：直连模式用品牌 Logo，正常模式用服务器图标。
    @ViewBuilder
    private var contextualAvatar: some View {
        if case .directAgent(let name) = message.source,
           let resolvedType = agentType ?? AgentType.from(displayName: name) {
            AgentLogoProvider.logo(for: resolvedType)
        } else {
            serverAvatar
        }
    }

    // MARK: - User Message (right-aligned, blue)
    private var userBubble: some View {
        HStack(alignment: .top, spacing: 8) {
            Spacer(minLength: 60)
            Text(message.content)
                .foregroundStyle(.white)
                .textSelection(.enabled)
                .padding(Theme.bubblePadding)
                .background(modeColors.userBubbleColor)
                .overlay {
                    if isDirectStyled {
                        RoundedRectangle(cornerRadius: Theme.bubbleCornerRadius)
                            .stroke(modeColors.accentColor.opacity(0.35), lineWidth: 1)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: Theme.bubbleCornerRadius))
                .shadow(color: bubbleShadowColor, radius: isDirectStyled ? 10 : 0, y: 4)
            userAvatar
        }
    }

    // MARK: - Assistant Message (left-aligned, gray)
    private var assistantBubble: some View {
        HStack(alignment: .top, spacing: 8) {
            contextualAvatar
            VStack(alignment: .leading, spacing: 6) {
                if let directAgentLabel {
                    HStack(spacing: 6) {
                        Image(systemName: "bolt.horizontal.circle.fill")
                        Text(directAgentLabel)
                    }
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(modeColors.accentColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(modeColors.accentColor.opacity(0.12))
                    .clipShape(Capsule())
                }

                if message.isLoading {
                    // Streaming state: thinking bubble shown separately in ChatView
                    if !agentStreamEvents.isEmpty {
                        // 编码代理模式：渲染结构化卡片
                        AgentStreamView(
                            events: agentStreamEvents,
                            isExecuting: isAgentExecuting,
                            accentColor: modeColors.accentColor
                        )
                    } else if let toolOutput = liveToolOutput, !toolOutput.isEmpty {
                        // 有输出 — 显示输出 + 海螺心跳（表示命令仍在运行）
                        VStack(alignment: .leading, spacing: 8) {
                            toolOutputView(toolOutput)
                            ConchHeartbeatView()
                        }
                    } else if let content = liveContentText, !content.isEmpty {
                        // 流式输出使用 Text，避免逐字重解析 markdown 的性能问题
                        Text(content)
                            .font(Theme.messageFont)
                            .foregroundStyle(modeColors.bubbleTextColor)
                            .textSelection(.enabled)
                            .padding(Theme.bubblePadding)
                            .background(modeColors.agentBubbleColor)
                            .overlay { assistantBubbleOutline }
                            .clipShape(RoundedRectangle(cornerRadius: Theme.bubbleCornerRadius))
                    } else if liveToolOutput != nil {
                        // liveToolOutput == "" — 工具刚启动，无输出，仅显示海螺心跳
                        ConchHeartbeatView()
                            .padding(Theme.bubblePadding)
                            .background(modeColors.agentBubbleColor)
                            .overlay { assistantBubbleOutline }
                            .clipShape(RoundedRectangle(cornerRadius: Theme.bubbleCornerRadius))
                    } else {
                        loadingDots
                    }
                } else {
                    // Persisted message: 使用自定义 MarkdownContentView 渲染
                    MarkdownContentView(content: message.content)
                        .foregroundStyle(modeColors.bubbleTextColor)
                        .padding(Theme.bubblePadding)
                        .background(modeColors.agentBubbleColor)
                        .overlay { assistantBubbleOutline }
                        .clipShape(RoundedRectangle(cornerRadius: Theme.bubbleCornerRadius))
                }
            }
            .shadow(color: bubbleShadowColor, radius: isDirectStyled ? 12 : 0, y: 4)
            Spacer(minLength: 28)
        }
    }

    /// 工具执行过程中的实时输出视图（终端风格）。
    private func toolOutputView(_ output: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "terminal")
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView {
                Text(output)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 200)
        }
        .padding(Theme.bubblePadding)
        .background(Color.primary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: Theme.bubbleCornerRadius))
    }

    private var loadingDots: some View {
        HStack(spacing: 4) {
            ForEach(0..<3) { i in
                Circle()
                    .fill(Color.secondary.opacity(0.3))
                    .frame(width: 8, height: 8)
                    .scaleEffect(message.isLoading ? 1.0 : 0.5)
                    .animation(
                        .easeInOut(duration: 0.6)
                            .repeatForever()
                            .delay(Double(i) * 0.2),
                        value: message.isLoading
                    )
            }
        }
        .padding(Theme.bubblePadding)
        .background(modeColors.agentBubbleColor)
        .overlay { assistantBubbleOutline }
        .clipShape(RoundedRectangle(cornerRadius: Theme.bubbleCornerRadius))
    }

    // MARK: - Command Message (expandable)
    private var commandBubble: some View {
        HStack(alignment: .top, spacing: 8) {
            contextualAvatar
            CommandDetailView(message: message)
        }
    }

    // MARK: - System Message (centered, with icon/color by type)
    @ViewBuilder
    private var systemBubble: some View {
        if message.systemMessageType == .commandDenied {
            deniedBubble
        } else if message.systemMessageType == .skillLoaded {
            skillLoadedBubble
        } else {
            HStack(spacing: 4) {
                if let icon = systemMessageIcon {
                    Image(systemName: icon)
                        .font(Theme.captionFont)
                        .foregroundStyle(systemMessageColor)
                }
                Text(message.content)
                    .font(Theme.captionFont)
                    .foregroundStyle(systemMessageColor)
            }
            .multilineTextAlignment(.center)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Skill Loaded Bubble (centered, fade-in)
    private var skillLoadedBubble: some View {
        HStack(spacing: 4) {
            Image(systemName: "wand.and.stars")
                .font(Theme.captionFont)
                .foregroundStyle(.secondary)
            Text(String(localized: "Loaded skill: \(message.content)", bundle: LanguageSettings.currentBundle))
                .font(Theme.captionFont)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity)
        .opacity(skillLoadedVisible ? 1 : 0)
        .onAppear {
            let isNew = Date().timeIntervalSince(message.timestamp) < 2
            if isNew {
                withAnimation(.easeIn(duration: 0.5)) {
                    skillLoadedVisible = true
                }
            } else {
                skillLoadedVisible = true
            }
        }
    }

    // MARK: - Denied Bubble (left-aligned, red)
    private var deniedBubble: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
                    .font(.caption)
                Text(String(localized: "Command Rejected", bundle: LanguageSettings.currentBundle))
                    .font(.callout)
                    .fontWeight(.medium)
                    .foregroundStyle(.red)
            }

            if let toolCall = message.toolCall {
                deniedDetailView(for: toolCall)
            }
        }
        .padding(Theme.bubblePadding)
        .background(Theme.deniedBubbleColor)
        .clipShape(RoundedRectangle(cornerRadius: Theme.bubbleCornerRadius))
    }

    /// 被拒绝命令的详情视图，显示工具名和命令内容。
    @ViewBuilder
    private func deniedDetailView(for toolCall: ToolCall) -> some View {
        let args = try? toolCall.decodedArguments()

        switch toolCall.toolName {
        case "execute_ssh_command":
            if let command = args?["command"] as? String {
                HStack {
                    Text("$")
                        .foregroundStyle(.red.opacity(0.6))
                    Text(command)
                        .textSelection(.enabled)
                        .strikethrough(true, color: .red.opacity(0.5))
                }
                .font(Theme.commandFont)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.red.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        default:
            Text(toolCall.explanation)
                .font(Theme.commandFont)
                .foregroundStyle(.secondary)
                .strikethrough(true, color: .red.opacity(0.5))
                .padding(8)
        }
    }

    /// 根据 `systemMessageType` 返回对应图标名称。
    private var systemMessageIcon: String? {
        switch message.systemMessageType {
        case .connected:       "bolt.fill"
        case .disconnected:    "bolt.slash"
        case .connectionLost:  "wifi.exclamationmark"
        case .reconnected:     "arrow.triangle.2.circlepath"
        case .connectionFailed: "exclamationmark.triangle"
        case .error:           "xmark.circle"
        case .info:            "info.circle"
        case .commandDenied:   "xmark.circle.fill"
        case .skillLoaded:     "wand.and.stars"
        case .aiContext:       nil  // 不在 UI 中显示
        case .contextBreak:   "scissors"  // 上下文断点图标
        case nil:              nil
        }
    }

    /// 根据 `systemMessageType` 返回对应颜色。
    private var systemMessageColor: Color {
        switch message.systemMessageType {
        case .connected:       .green
        case .disconnected:    .secondary
        case .connectionLost:  .red
        case .reconnected:     .orange
        case .connectionFailed: .red
        case .error:           .orange
        case .commandDenied:   .red
        case .skillLoaded:     .secondary
        case .aiContext:       .clear  // 不在 UI 中显示
        case .contextBreak:   .secondary  // 上下文断点颜色
        case .info, nil:       .secondary
        }
    }

    @ViewBuilder
    private var assistantBubbleOutline: some View {
        if isDirectStyled {
            RoundedRectangle(cornerRadius: Theme.bubbleCornerRadius)
                .stroke(.white.opacity(0.16), lineWidth: 1)
        }
    }

    private var isDirectStyled: Bool {
        if presentationState?.isActive == true { return true }
        if case .directAgent = message.source { return true }
        return false
    }

    private var directAgentLabel: String? {
        guard case .directAgent(let name) = message.source else { return nil }
        return name
    }

    private var bubbleShadowColor: Color {
        guard isDirectStyled else { return .clear }
        return modeColors.accentColor.opacity(0.22)
    }
}
