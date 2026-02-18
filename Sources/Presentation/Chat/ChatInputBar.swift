import SwiftUI

struct ChatInputBar: View {
    @Binding var text: String
    let isProcessing: Bool
    let isConnected: Bool
    let onSend: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
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
                        onSend()
                    }
                }

            Button(action: onSend) {
                Group {
                    if isProcessing {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Image(systemName: "arrow.up")
                            .fontWeight(.semibold)
                    }
                }
                .frame(width: 32, height: 32)
                .background(canSend ? Theme.userBubbleColor : Color.secondary.opacity(0.3))
                .clipShape(Circle())
                .foregroundStyle(.white)
            }
            .disabled(!canSend)
        }
        .padding(.horizontal, Theme.screenPadding)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isProcessing && isConnected
    }
}
