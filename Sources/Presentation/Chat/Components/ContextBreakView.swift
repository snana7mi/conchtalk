/// 文件说明：ContextBreakView，上下文分割分隔线 UI 组件。
import SwiftUI

/// ContextBreakView：
/// 显示"已清理上下文 · 时间"分隔线，标记 AI 上下文的起始边界。
struct ContextBreakView: View {
    let timestamp: Date

    var body: some View {
        HStack(spacing: 8) {
            line
            Text(labelText)
                .font(.caption2)
                .foregroundStyle(Color.secondary.opacity(0.5))
            line
        }
        .padding(.vertical, 12)
    }

    private var line: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.3))
            .frame(height: 0.5)
    }

    private var labelText: String {
        let timeString = timestamp.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(LanguageSettings.currentLocale))
        return String(localized: "Context cleared · \(timeString)", bundle: LanguageSettings.currentBundle)
    }
}
