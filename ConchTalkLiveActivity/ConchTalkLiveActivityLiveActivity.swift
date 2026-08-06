/// 文件说明：ConchTalkLiveActivityWidget，海螺主题灵动岛与锁屏 Live Activity UI。
import ActivityKit
import SwiftUI
import WidgetKit

/// ConchTalkLiveActivityWidget：
/// 渲染灵动岛（紧凑/最小/展开视图）和锁屏 Widget。
/// 海螺主题，支持多服务器聚合展示。
struct ConchTalkLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ConchTalkActivityAttributes.self) { context in
            // 锁屏视图
            lockScreenView(servers: context.state.servers)
        } dynamicIsland: { context in
            DynamicIsland {
                // 展开视图
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 4) {
                        Image(systemName: "fossil.shell.fill")
                            .foregroundStyle(.teal)
                        Text("ConchTalk")
                            .font(.caption.weight(.semibold))
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    EmptyView()
                }
                DynamicIslandExpandedRegion(.bottom) {
                    expandedServerList(servers: context.state.servers)
                }
            } compactLeading: {
                Image(systemName: "fossil.shell.fill")
                    .foregroundStyle(.teal)
            } compactTrailing: {
                compactTrailingView(servers: context.state.servers)
            } minimal: {
                Image(systemName: "fossil.shell.fill")
                    .foregroundStyle(.teal)
            }
        }
    }

    // MARK: - 紧凑视图右侧

    @ViewBuilder
    private func compactTrailingView(servers: [ServerSnapshot]) -> some View {
        if servers.count == 1, let server = servers.first {
            Text(server.serverName)
                .font(.caption2)
                .lineLimit(1)
        } else if servers.count > 1 {
            Text("\(servers.count) Servers")
                .font(.caption2)
        }
    }

    // MARK: - 展开视图服务器列表

    @ViewBuilder
    private func expandedServerList(servers: [ServerSnapshot]) -> some View {
        let displayServers = Array(servers.prefix(3))
        let remaining = servers.count - 3

        VStack(alignment: .leading, spacing: 6) {
            ForEach(displayServers, id: \.serverID) { server in
                serverRow(server: server)
            }
            if remaining > 0 {
                Text("+\(remaining) more")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// 单个服务器的两行展示。
    @ViewBuilder
    private func serverRow(server: ServerSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            // 第一行：状态圆点 + 服务器名 + 最新回复
            HStack(spacing: 4) {
                Circle()
                    .fill(server.hasActiveTask ? .orange : .green)
                    .frame(width: 6, height: 6)
                Text(server.serverName)
                    .font(.caption.weight(.medium))
                if !server.lastReply.isEmpty {
                    Text(server.lastReply)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            // 第二行：CPU · MEM · 连接时长
            HStack(spacing: 8) {
                Label("CPU \(formatPercent(server.cpuUsage))", systemImage: "cpu")
                Label("MEM \(formatPercent(server.memoryUsage))", systemImage: "memorychip")
                Label(formatDuration(server.connectionSeconds), systemImage: "clock")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - 锁屏视图

    @ViewBuilder
    private func lockScreenView(servers: [ServerSnapshot]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // 标题行
            HStack {
                Image(systemName: "fossil.shell.fill")
                    .foregroundStyle(.teal)
                Text("ConchTalk")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if servers.count > 1 {
                    Text("\(servers.count) Servers")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            let displayServers = Array(servers.prefix(3))
            let remaining = servers.count - 3

            ForEach(displayServers, id: \.serverID) { server in
                serverRow(server: server)
            }
            if remaining > 0 {
                Text("+\(remaining) more")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
    }

    // MARK: - Helpers

    /// 0-1 小数转百分比显示。
    /// ServerSnapshot 内 cpuUsage/memoryUsage 恒为 0-1 范围。
    /// 保留 value > 1 的兼容处理作为安全兜底。
    private func formatPercent(_ value: Double) -> String {
        let normalized = value > 1 ? value / 100.0 : value
        let percent = normalized * 100
        if percent > 0 && percent < 1 {
            return "<1%"
        }
        if percent <= 0 {
            return "0%"
        }
        return "\(Int(percent.rounded()))%"
    }

    private func formatDuration(_ seconds: Int) -> String {
        if seconds >= 3600 {
            let h = seconds / 3600
            let m = (seconds % 3600) / 60
            let s = seconds % 60
            return String(format: "%d:%02d:%02d", h, m, s)
        } else {
            let m = seconds / 60
            let s = seconds % 60
            return String(format: "%d:%02d", m, s)
        }
    }
}

// MARK: - Preview

extension ConchTalkActivityAttributes {
    fileprivate static var preview: ConchTalkActivityAttributes {
        ConchTalkActivityAttributes()
    }
}

extension ConchTalkActivityAttributes.ContentState {
    fileprivate static var singleServer: ConchTalkActivityAttributes.ContentState {
        ConchTalkActivityAttributes.ContentState(servers: [
            ServerSnapshot(serverID: UUID(), serverName: "My Server", lastReply: "文件已创建：/home/user/test.txt", cpuUsage: 0.23, memoryUsage: 0.45, connectionSeconds: 4355, hasActiveTask: true),
        ])
    }

    fileprivate static var multiServer: ConchTalkActivityAttributes.ContentState {
        ConchTalkActivityAttributes.ContentState(servers: [
            ServerSnapshot(serverID: UUID(), serverName: "My Server", lastReply: "文件已创建：/home/user/test.txt", cpuUsage: 0.23, memoryUsage: 0.45, connectionSeconds: 4355, hasActiveTask: true),
            ServerSnapshot(serverID: UUID(), serverName: "Production", lastReply: "系统负载正常，CPU 使用率 23%", cpuUsage: 0.67, memoryUsage: 0.82, connectionSeconds: 13520, hasActiveTask: false),
        ])
    }
}

#Preview("Single Server", as: .content, using: ConchTalkActivityAttributes.preview) {
    ConchTalkLiveActivityWidget()
} contentStates: {
    ConchTalkActivityAttributes.ContentState.singleServer
}

#Preview("Multi Server", as: .content, using: ConchTalkActivityAttributes.preview) {
    ConchTalkLiveActivityWidget()
} contentStates: {
    ConchTalkActivityAttributes.ContentState.multiServer
}
