/// 文件说明：CpuCoreRingView，单个 CPU 核心利用率环形图组件。

import SwiftUI

/// CpuCoreRingView：
/// 显示单个 CPU 核心的利用率环形图，颜色随利用率变化（绿<50%、橙50-80%、红>80%）。
struct CpuCoreRingView: View {
    let coreIndex: Int
    let usage: Double  // 0.0-1.0

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                // 背景环
                Circle()
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 4)

                // 利用率环
                Circle()
                    .trim(from: 0, to: usage)
                    .stroke(usageColor, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))

                // 百分比文字
                Text("\(Int(usage * 100))%")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(usageColor)
            }
            .frame(width: 52, height: 52)

            Text("Core \(coreIndex + 1)")  // "Core N" 作为技术标签不做本地化
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var usageColor: Color {
        switch usage {
        case ..<0.5: .green
        case 0.5..<0.8: .orange
        default: .red
        }
    }
}

#Preview {
    HStack {
        CpuCoreRingView(coreIndex: 0, usage: 0.3)
        CpuCoreRingView(coreIndex: 1, usage: 0.65)
        CpuCoreRingView(coreIndex: 2, usage: 0.92)
    }
    .padding()
}
