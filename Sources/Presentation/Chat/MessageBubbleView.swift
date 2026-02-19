/// 文件说明：MessageBubbleView，负责聊天模块的界面展示与交互流程。
import SwiftUI

/// MessageBubbleView：负责界面渲染与用户交互响应。
struct MessageBubbleView: View {
    let message: Message
    var liveContentText: String? = nil

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

    // MARK: - User Message (right-aligned, blue)
    private var userBubble: some View {
        HStack {
            Spacer(minLength: 60)
            Text(message.content)
                .font(Theme.messageFont)
                .foregroundStyle(.white)
                .padding(Theme.bubblePadding)
                .background(Theme.userBubbleColor)
                .clipShape(RoundedRectangle(cornerRadius: Theme.bubbleCornerRadius))
        }
    }

    // MARK: - Assistant Message (left-aligned, gray)
    private var assistantBubble: some View {
        HStack {
            VStack(alignment: .leading, spacing: 6) {
                if message.isLoading {
                    // Streaming state: thinking bubble shown separately in ChatView
                    if let content = liveContentText, !content.isEmpty {
                        Text(content)
                            .font(Theme.messageFont)
                            .padding(Theme.bubblePadding)
                            .background(Theme.assistantBubbleColor)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.bubbleCornerRadius))
                    } else {
                        loadingDots
                    }
                } else {
                    // Persisted message: reasoning shown separately in ChatView
                    Text(message.content)
                        .font(Theme.messageFont)
                        .padding(Theme.bubblePadding)
                        .background(Theme.assistantBubbleColor)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.bubbleCornerRadius))
                }
            }
            Spacer(minLength: 60)
        }
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
        .background(Theme.assistantBubbleColor)
        .clipShape(RoundedRectangle(cornerRadius: Theme.bubbleCornerRadius))
    }

    // MARK: - Command Message (expandable)
    private var commandBubble: some View {
        CommandDetailView(message: message)
    }

    // MARK: - System Message (centered, subtle)
    private var systemBubble: some View {
        Text(message.content)
            .font(Theme.captionFont)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity)
    }
}
