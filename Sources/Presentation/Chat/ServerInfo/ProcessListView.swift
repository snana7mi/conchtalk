/// 文件说明：ProcessListView，进程 Top 5 列表组件，支持 CPU/MEM 排序切换。

import SwiftUI

/// ProcessListView：
/// 显示占用率最高的 5 个进程，支持按 CPU 或内存排序切换。
struct ProcessListView: View {
    let processes: [ProcessInfo]
    @Binding var sortMode: ProcessSortMode

    var body: some View {
        VStack(spacing: 0) {
            // 标题 + 排序切换
            HStack {
                Text(String(localized: "Processes TOP 5", bundle: LanguageSettings.currentBundle))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
                Picker("", selection: $sortMode) {
                    ForEach(ProcessSortMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 100)
            }
            .padding(.bottom, 8)

            // 表头
            HStack(spacing: 0) {
                Text("#").frame(width: 20, alignment: .leading)
                Text(String(localized: "Process Name", bundle: LanguageSettings.currentBundle)).frame(maxWidth: .infinity, alignment: .leading)
                Text("CPU").frame(width: 50, alignment: .trailing)
                Text("MEM").frame(width: 50, alignment: .trailing)
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tertiary)
            .padding(.bottom, 6)

            Divider()

            // 进程行
            ForEach(Array(processes.prefix(5).enumerated()), id: \.element.id) { index, proc in
                HStack(spacing: 0) {
                    Text("\(index + 1)").frame(width: 20, alignment: .leading)
                        .foregroundStyle(.secondary)
                    Text(proc.name).frame(maxWidth: .infinity, alignment: .leading)
                        .lineLimit(1)
                    Text(String(format: "%.1f%%", proc.cpuPercent))
                        .frame(width: 50, alignment: .trailing)
                        .foregroundStyle(.orange)
                    Text(String(format: "%.1f%%", proc.memPercent))
                        .frame(width: 50, alignment: .trailing)
                        .foregroundStyle(.green)
                }
                .font(.caption.weight(.medium))
                .padding(.vertical, 6)

                if index < min(processes.count, 5) - 1 {
                    Divider()
                }
            }
        }
    }
}

#Preview {
    ProcessListView(
        processes: [
            ProcessInfo(pid: 1, name: "node", cpuPercent: 45.2, memPercent: 3.1),
            ProcessInfo(pid: 2, name: "python3", cpuPercent: 22.8, memPercent: 8.5),
            ProcessInfo(pid: 3, name: "nginx", cpuPercent: 12.1, memPercent: 1.2),
            ProcessInfo(pid: 4, name: "postgres", cpuPercent: 8.7, memPercent: 12.4),
            ProcessInfo(pid: 5, name: "redis-server", cpuPercent: 3.4, memPercent: 2.1),
        ],
        sortMode: .constant(.cpu)
    )
    .padding()
}
