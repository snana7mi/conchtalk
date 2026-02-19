import SwiftUI

struct ThinkingBubbleView: View {
    let reasoningContent: String
    let isLiveStreaming: Bool

    @State private var isExpanded = false
    @State private var previousStreamingState = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "brain")
                        .foregroundStyle(.purple)
                        .font(.caption)

                    Text("Thinking")
                        .font(.callout)
                        .foregroundStyle(.primary)

                    if isLiveStreaming {
                        PulsingDot()
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
            }
            .buttonStyle(.plain)

            if isExpanded {
                Text(reasoningContent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(Theme.bubblePadding)
        .background(Theme.reasoningBubbleColor)
        .clipShape(RoundedRectangle(cornerRadius: Theme.bubbleCornerRadius))
        .onChange(of: isLiveStreaming) { oldValue, newValue in
            if !oldValue && newValue {
                // Started streaming → expand
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded = true
                }
            } else if oldValue && !newValue {
                // Stopped streaming → collapse after delay
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(500))
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isExpanded = false
                    }
                }
            }
        }
        .onAppear {
            if isLiveStreaming {
                // Live streaming starts expanded
                isExpanded = true
            } else if !reasoningContent.isEmpty {
                // Persisted thinking: start expanded, then auto-collapse
                // This provides visual continuity from the streaming state
                isExpanded = true
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(800))
                    withAnimation(.easeInOut(duration: 0.3)) {
                        isExpanded = false
                    }
                }
            }
        }
    }
}

// MARK: - Pulsing Dot Indicator

private struct PulsingDot: View {
    @State private var isAnimating = false

    var body: some View {
        Circle()
            .fill(Color.purple)
            .frame(width: 6, height: 6)
            .opacity(isAnimating ? 0.3 : 1.0)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                    isAnimating = true
                }
            }
    }
}
