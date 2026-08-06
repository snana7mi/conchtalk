/// 文件说明：ConchHeartbeatView，海螺心跳动画，在命令执行等待输出时显示。
import SwiftUI

/// ConchHeartbeatView：海螺 + 音频均衡器条动画。
/// 用于指示 SSH 命令正在后台执行，尚未产生输出。
struct ConchHeartbeatView: View {
    var body: some View {
        HStack(spacing: 6) {
            Text("\u{1F41A}")
                .font(.system(size: 16))

            HStack(alignment: .center, spacing: 2.5) {
                ForEach(0..<4, id: \.self) { i in
                    SoundBar(delay: Double(i) * 0.15)
                }
            }
            .frame(height: 16)

            Text(String(localized: "Running...", bundle: LanguageSettings.currentBundle))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// 单个均衡器竖条，独立驱动动画以实现交错效果。
private struct SoundBar: View {
    let delay: Double
    @State private var animating = false

    var body: some View {
        RoundedRectangle(cornerRadius: 1.5)
            .fill(Color.orange.opacity(animating ? 1.0 : 0.4))
            .frame(width: 2.5, height: animating ? 14 : 4)
            .animation(
                .easeInOut(duration: 0.6)
                    .repeatForever(autoreverses: true)
                    .delay(delay),
                value: animating
            )
            .onAppear {
                animating = true
            }
    }
}
