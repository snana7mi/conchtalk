import SwiftUI

struct CommandDetailView: View {
    let message: Message
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Command header
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "terminal")
                        .foregroundStyle(statusColor)
                        .font(.caption)

                    Text(message.command?.explanation ?? message.content)
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .lineLimit(isExpanded ? nil : 1)

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
            }
            .buttonStyle(.plain)

            if isExpanded {
                // Command line
                if let cmd = message.command {
                    HStack {
                        Text("$")
                            .foregroundStyle(.secondary)
                        Text(cmd.command)
                            .textSelection(.enabled)
                    }
                    .font(Theme.commandFont)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }

                // Output
                if let output = message.commandOutput, !output.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(output)
                            .font(Theme.commandFont)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 200)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
        }
        .padding(Theme.bubblePadding)
        .background(Theme.commandBubbleColor)
        .clipShape(RoundedRectangle(cornerRadius: Theme.bubbleCornerRadius))
    }

    private var statusColor: Color {
        if let cmd = message.command {
            return cmd.isDestructive ? .orange : .green
        }
        return .blue
    }
}
