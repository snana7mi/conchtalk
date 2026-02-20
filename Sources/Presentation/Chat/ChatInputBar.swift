/// 文件说明：ChatInputBar，负责聊天模块的界面展示与交互流程。
import SwiftUI

/// ChatInputBar：UI 层组件，承载展示与交互职责。
struct ChatInputBar: View {
    @Binding var text: String
    let isProcessing: Bool
    let isConnected: Bool
    var contextUsagePercent: Double = 0
    let onSend: () -> Void
    var onStop: (() -> Void)?

    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 4) {
            // Context usage indicator
            if contextUsagePercent > 0.01 {
                HStack {
                    Spacer()
                    Text("\(Int(contextUsagePercent * 100))%")
                        .font(.caption2)
                        .fontWeight(.medium)
                        .foregroundStyle(contextUsageColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(contextUsageColor.opacity(0.15))
                        .clipShape(Capsule())
                }
                .padding(.horizontal, Theme.screenPadding)
            }

            HStack(alignment: .bottom, spacing: 8) {
                TextField("Type a message...", text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.secondary.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                    .focused($isFocused)
                    .disabled(!isConnected)
                    .onSubmit {
                        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            isFocused = false
                            onSend()
                        }
                    }

                if isProcessing {
                    Button {
                        onStop?()
                    } label: {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 14))
                            .frame(width: 32, height: 32)
                            .background(Color.red)
                            .clipShape(Circle())
                            .foregroundStyle(.white)
                    }
                } else {
                    Button {
                        isFocused = false
                        onSend()
                    } label: {
                        Image(systemName: "arrow.up")
                            .fontWeight(.semibold)
                            .frame(width: 32, height: 32)
                            .background(canSend ? Theme.userBubbleColor : Color.secondary.opacity(0.3))
                            .clipShape(Circle())
                            .foregroundStyle(.white)
                    }
                    .disabled(!canSend)
                }
            }
        }
        .padding(.horizontal, Theme.screenPadding)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var contextUsageColor: Color {
        if contextUsagePercent > 0.95 {
            return .red
        } else if contextUsagePercent > 0.70 {
            return .yellow
        } else {
            return .green
        }
    }

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isProcessing && isConnected
    }
}
