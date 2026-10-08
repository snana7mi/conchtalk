/// 文件说明：UserQuestionCardView，渲染 AI 通过 ask_user 提出的问题：可点选项 + 自由输入提示。
import SwiftUI

/// UserQuestionCardView：
/// - `onSelect` 非 nil（该问题是最新消息且没有任务在运行）时选项可点，点选即作为用户回复发送；
/// - 已回答 / 过期的问题仅展示，选项置灰。
struct UserQuestionCardView: View {
    let question: UserQuestion
    var onSelect: ((String) -> Void)? = nil

    private var isActive: Bool { onSelect != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text(question.question)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "questionmark.bubble.fill")
                    .foregroundStyle(.purple)
            }

            if !question.options.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(question.options, id: \.self) { option in
                        Button {
                            onSelect?(option)
                        } label: {
                            Text(option)
                                .font(.callout)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(Color.purple.opacity(isActive ? 0.12 : 0.05))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(isActive ? Color.purple : Color.secondary)
                        .disabled(!isActive)
                        .accessibilityHint(isActive ? String(localized: "Sends this answer", bundle: LanguageSettings.currentBundle) : "")
                    }
                }
            }

            if isActive {
                Text(question.options.isEmpty
                     ? String(localized: "Type your answer below.", bundle: LanguageSettings.currentBundle)
                     : String(localized: "Or type your own answer below.", bundle: LanguageSettings.currentBundle))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(Theme.bubblePadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.purple.opacity(0.06))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.bubbleCornerRadius)
                .stroke(Color.purple.opacity(isActive ? 0.35 : 0.12), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.bubbleCornerRadius))
    }
}
