/// 文件说明：AgentStreamView，编码代理流式输出的结构化卡片渲染组件。

import SwiftUI

/// AgentStreamView：渲染编码代理的流式事件为结构化卡片。
struct AgentStreamView: View {
    let events: [AgentStreamEvent]
    let isExecuting: Bool
    var accentColor: Color = .orange
    @State private var mergedEvents: [AgentStreamEvent]

    init(events: [AgentStreamEvent], isExecuting: Bool, accentColor: Color = .orange) {
        self.events = events
        self.isExecuting = isExecuting
        self.accentColor = accentColor
        _mergedEvents = State(initialValue: Self.mergeContentEvents(events))
    }

    /// 从事件流中提取代理名称，回退到默认值。
    private var agentName: String {
        for event in events {
            if case .agentConnected(let name) = event { return name }
        }
        return "Coding Agent"
    }

    /// 合并连续同类型事件（thinking/text chunks → 单条），过滤元事件。
    private static func mergeContentEvents(_ events: [AgentStreamEvent]) -> [AgentStreamEvent] {
        var merged: [AgentStreamEvent] = []
        for event in events {
            switch event {
            case .agentConnected, .completed:
                continue
            case .thinking(let text):
                if case .thinking(let prev) = merged.last {
                    merged[merged.count - 1] = .thinking(prev + text)
                } else {
                    merged.append(event)
                }
            case .text(let text):
                if case .text(let prev) = merged.last {
                    merged[merged.count - 1] = .text(prev + text)
                } else {
                    merged.append(event)
                }
            default:
                merged.append(event)
            }
        }
        return merged
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            agentHeader

            ForEach(Array(mergedEvents.enumerated()), id: \.offset) { _, event in
                eventCard(for: event)
            }

            if isExecuting {
                HStack(spacing: 6) {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text(String(localized: "代理执行中...", bundle: LanguageSettings.currentBundle))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
            }
        }
        .padding(.vertical, 8)
        .onChange(of: events) { _, newEvents in
            mergedEvents = Self.mergeContentEvents(newEvents)
        }
    }

    private var agentHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "bolt.fill")
                .foregroundStyle(accentColor)
            Text(agentName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func eventCard(for event: AgentStreamEvent) -> some View {
        switch event {
        case .agentConnected:
            EmptyView()  // 由 agentHeader 渲染，不在卡片流中显示
        case .thinking(let text):
            thinkingCard(text: text)
        case .text(let text):
            textCard(text: text)
        case .toolCall(let name, let arguments, let status):
            toolCallCard(name: name, arguments: arguments, status: status)
        case .toolResult(let name, let result):
            toolResultCard(name: name, result: result)
        case .plan(let entries):
            planCard(entries: entries)
        case .completed:
            completedCard
        }
    }

    // MARK: - 卡片样式

    private func thinkingCard(text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label {
                Text(String(localized: "思考", bundle: LanguageSettings.currentBundle))
                    .font(.caption)
            } icon: {
                Image(systemName: "brain")
            }
            .foregroundStyle(accentColor.opacity(0.8))

            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(accentColor.opacity(0.08))
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(accentColor.opacity(0.5))
                .frame(width: 3)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 12)
    }

    private func textCard(text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
    }

    private func toolCallCard(name: String, arguments: String, status: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label {
                Text(name)
                    .font(.caption.monospaced())
            } icon: {
                Image(systemName: toolIcon(for: name))
            }
            .foregroundStyle(toolColor(for: name))

            if !arguments.isEmpty {
                Text(arguments)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(toolColor(for: name).opacity(0.08))
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(toolColor(for: name).opacity(0.5))
                .frame(width: 3)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 12)
    }

    private func toolResultCard(name: String, result: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label {
                Text(name)
                    .font(.caption.monospaced())
            } icon: {
                Image(systemName: "checkmark.circle.fill")
            }
            .foregroundStyle(.green)

            Text(result)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(4)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.green.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 12)
    }

    private func planCard(entries: [AgentPlanEntry]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label {
                Text(String(localized: "执行计划", bundle: LanguageSettings.currentBundle))
                    .font(.caption)
            } icon: {
                Image(systemName: "list.bullet.clipboard")
            }
            .foregroundStyle(.blue)

            ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                HStack(spacing: 6) {
                    Image(systemName: planStatusIcon(entry.status))
                        .font(.caption2)
                    Text(entry.title)
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.blue.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 12)
    }

    private var completedCard: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text(String(localized: "任务完成", bundle: LanguageSettings.currentBundle))
                .font(.caption.weight(.medium))
                .foregroundStyle(.green)
        }
        .padding(.horizontal, 12)
    }

    // MARK: - 工具样式辅助

    private func toolIcon(for name: String) -> String {
        ToolDisplayInfo.fuzzyInfo(for: name).iconName
    }

    private func toolColor(for name: String) -> Color {
        ToolDisplayInfo.fuzzyInfo(for: name).color
    }

    private func planStatusIcon(_ status: String?) -> String {
        switch status {
        case "completed": return "checkmark.circle.fill"
        case "in_progress": return "circle.dotted"
        default: return "circle"
        }
    }
}
