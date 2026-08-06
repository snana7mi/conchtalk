/// 文件说明：MemoryRingView，内存利用率环形图及详情组件。

import SwiftUI

/// MemoryRingView：
/// 显示内存利用率大环形图，附带已用/总计/可用的详细数据行。
struct MemoryRingView: View {
    let usagePercent: Double  // 0.0-1.0
    let used: UInt64
    let total: UInt64
    let available: UInt64

    var body: some View {
        HStack(spacing: 12) {
            // 环形图
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 5)
                Circle()
                    .trim(from: 0, to: usagePercent)
                    .stroke(usageColor, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(Int(usagePercent * 100))%")
                    .font(.callout.weight(.bold))
                    .foregroundStyle(usageColor)
            }
            .frame(width: 64, height: 64)

            // 详情
            VStack(spacing: 6) {
                infoRow(
                    label: String(localized: "Used", bundle: LanguageSettings.currentBundle),
                    value: formatBytes(used)
                )
                infoRow(
                    label: String(localized: "Total", bundle: LanguageSettings.currentBundle),
                    value: formatBytes(total)
                )
                infoRow(
                    label: String(localized: "Available", bundle: LanguageSettings.currentBundle),
                    value: formatBytes(available),
                    valueColor: .green
                )
            }
        }
    }

    private var usageColor: Color {
        switch usagePercent {
        case ..<0.5: .green
        case 0.5..<0.8: .orange
        default: .red
        }
    }

    private func infoRow(label: String, value: String, valueColor: Color? = nil) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.caption.weight(.medium))
                .foregroundStyle(valueColor ?? .primary)
        }
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 1 {
            return String(format: "%.1f GB", gb)
        }
        let mb = Double(bytes) / 1_048_576
        return String(format: "%.0f MB", mb)
    }
}

#Preview {
    MemoryRingView(
        usagePercent: 0.68,
        used: 10_880_000_000,
        total: 16_000_000_000,
        available: 5_120_000_000
    )
    .padding()
}
