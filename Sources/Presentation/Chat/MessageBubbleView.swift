import SwiftUI

struct MessageBubbleView: View {
    let message: Message
    var liveReasoningText: String? = nil
    var liveContentText: String? = nil
    var isStreaming: Bool = false

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
                    // Streaming state: show live reasoning and/or content
                    if let reasoning = liveReasoningText, !reasoning.isEmpty {
                        ThinkingBubbleView(
                            reasoningContent: reasoning,
                            isLiveStreaming: isStreaming
                        )
                    }

                    if let content = liveContentText, !content.isEmpty {
                        Text(content)
                            .font(Theme.messageFont)
                            .padding(Theme.bubblePadding)
                            .background(Theme.assistantBubbleColor)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.bubbleCornerRadius))
                    } else if liveReasoningText == nil || liveReasoningText!.isEmpty {
                        // No streaming data yet — show loading dots
                        loadingDots
                    }
                } else {
                    // Persisted message: show saved reasoning if any
                    if let reasoning = message.reasoningContent, !reasoning.isEmpty {
                        ThinkingBubbleView(
                            reasoningContent: reasoning,
                            isLiveStreaming: false
                        )
                    }

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
