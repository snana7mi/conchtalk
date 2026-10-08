/// 文件说明：PlanChecklistView，执行计划清单卡片（直连模式 ACP plan 与普通模式 update_plan 共用）。
import SwiftUI

/// PlanChecklistView：按状态显示计划步骤（完成 / 进行中 / 待办）。
struct PlanChecklistView: View {
    let entries: [AgentPlanEntry]
    var note: String? = nil
    var tint: Color = .blue
    /// 紧凑样式（直连模式流式卡片）使用 caption 字号且弱化文字。
    var compact: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 4 : 6) {
            HStack(spacing: 6) {
                Label {
                    Text(String(localized: "执行计划", bundle: LanguageSettings.currentBundle))
                        .font(compact ? .caption : .subheadline.weight(.medium))
                } icon: {
                    Image(systemName: "list.bullet.clipboard")
                }
                .foregroundStyle(tint)

                if !compact, !entries.isEmpty {
                    Spacer(minLength: 8)
                    Text(verbatim: "\(completedCount)/\(entries.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            if let note, !note.isEmpty {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: Self.statusIcon(entry.status))
                        .font(compact ? .caption2 : .caption)
                        .foregroundStyle(compact ? Color.secondary : Self.statusColor(entry.status, tint: tint))
                    Text(entry.title)
                        .font(compact ? .caption : .callout)
                        .foregroundStyle(compact || entry.status != "completed" ? Color.secondary : Color.secondary.opacity(0.7))
                        .strikethrough(!compact && entry.status == "completed", color: .secondary.opacity(0.5))
                        .fontWeight(!compact && entry.status == "in_progress" ? .semibold : .regular)
                }
                .accessibilityElement(children: .combine)
                .accessibilityValue(Self.accessibilityStatus(entry.status))
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var completedCount: Int {
        entries.filter { $0.status == "completed" }.count
    }

    static func statusIcon(_ status: String?) -> String {
        switch status {
        case "completed": return "checkmark.circle.fill"
        case "in_progress": return "circle.dotted"
        default: return "circle"
        }
    }

    private static func statusColor(_ status: String?, tint: Color) -> Color {
        switch status {
        case "completed": return .green
        case "in_progress": return tint
        default: return .secondary
        }
    }

    private static func accessibilityStatus(_ status: String?) -> String {
        switch status {
        case "completed": return String(localized: "Completed", bundle: LanguageSettings.currentBundle)
        case "in_progress": return String(localized: "In Progress", bundle: LanguageSettings.currentBundle)
        default: return String(localized: "Pending", bundle: LanguageSettings.currentBundle)
        }
    }
}
