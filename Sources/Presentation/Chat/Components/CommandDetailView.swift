/// 文件说明：CommandDetailView，负责聊天模块的界面展示与交互流程。
import SwiftUI

/// CommandDetailView：负责界面渲染与用户交互响应。
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
                    Image(systemName: iconName)
                        .foregroundStyle(statusColor)
                        .font(.caption)

                    Text(message.toolCall?.explanation ?? message.content)
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
                // Detail line (varies by tool type)
                if let toolCall = message.toolCall {
                    detailView(for: toolCall)
                }

                // Output
                if let output = message.toolOutput, !output.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(friendlyOutput(output))
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

    /// detailView：根据工具类型渲染对应的详情视图。
    @ViewBuilder
    private func detailView(for toolCall: ToolCall) -> some View {
        let args = try? toolCall.decodedArguments()

        switch toolCall.toolName {
        case "execute_ssh_command":
            if let command = args?["command"] as? String {
                HStack {
                    Text("$")
                        .foregroundStyle(.secondary)
                    Text(command)
                        .textSelection(.enabled)
                }
                .font(Theme.commandFont)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

        case "read_file", "write_file":
            if let path = args?["path"] as? String {
                Label(path, systemImage: toolCall.toolName.contains("write") ? "doc.text.fill" : "doc.text")
                    .font(Theme.commandFont)
                    .foregroundStyle(.secondary)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }

        default:
            Text(toolCall.toolName)
                .font(Theme.commandFont)
                .foregroundStyle(.secondary)
                .padding(8)
        }
    }

    private var iconName: String {
        guard let toolName = message.toolCall?.toolName else { return "terminal" }
        return ToolDisplayInfo.info(for: toolName).iconName
    }

    private var statusColor: Color {
        guard let toolCall = message.toolCall else { return .blue }
        let args = try? toolCall.decodedArguments()
        return ToolDisplayInfo.statusColor(for: toolCall.toolName, args: args)
    }

    /// 工具输出友好展示。
    private func friendlyOutput(_ output: String) -> String {
        return output.strippingANSIEscapes()
    }
}
