/// 文件说明：SSHConnectionProgressView，全屏终端风格的 SSH 连接进度动画视图。
import SwiftUI

/// SSHConnectionProgressView：
/// 左侧时间线展示 5 个连接阶段，右侧日志区逐行显示 SSH 协议握手细节。
struct SSHConnectionProgressView: View {
    var viewModel: SSHConnectionProgressViewModel

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // 左侧时间线
            timeline
                .frame(width: 130)
                .padding(.top, 24)

            Divider()
                .background(Theme.terminalTextDimColor)

            // 右侧日志区
            logArea
                .padding(.top, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.terminalBackground)
    }

    // MARK: - 左侧时间线

    private var timeline: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(viewModel.stages.enumerated()), id: \.element.id) { index, stage in
                HStack(alignment: .top, spacing: 8) {
                    // 圆点指示器
                    stageIndicator(for: stage.status)
                        .frame(width: 12, height: 12)

                    // 阶段名
                    Text(stage.title)
                        .font(Theme.terminalFont)
                        .foregroundStyle(stageTextColor(for: stage.status))
                        .lineLimit(1)
                }
                .padding(.vertical, 6)

                // 竖线连接器（最后一个阶段不画）
                if index < viewModel.stages.count - 1 {
                    HStack(spacing: 0) {
                        Rectangle()
                            .fill(connectorColor(for: stage.status))
                            .frame(width: 2, height: 20)
                            .padding(.leading, 5)
                        Spacer()
                    }
                }
            }
            Spacer()
        }
        .padding(.horizontal, 16)
    }

    // MARK: - 右侧日志区

    private var logArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(viewModel.logLines) { line in
                        Text(line.text)
                            .font(Theme.terminalFont)
                            .foregroundStyle(logLineColor(for: line.type))
                            .id(line.id)
                            .transition(.opacity)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .onChange(of: viewModel.logLines.count) {
                if let last = viewModel.logLines.last {
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    // MARK: - 样式辅助

    @ViewBuilder
    private func stageIndicator(for status: StageStatus) -> some View {
        switch status {
        case .pending:
            Circle()
                .strokeBorder(Color.secondary.opacity(0.4), lineWidth: 1.5)
        case .active:
            PulsingCircle()
        case .completed:
            Circle()
                .fill(Color.green)
        case .failed:
            Circle()
                .fill(Color.red)
        }
    }

    private func stageTextColor(for status: StageStatus) -> Color {
        switch status {
        case .pending: Color.secondary.opacity(0.4)
        case .active: Theme.terminalTextColor
        case .completed: Theme.terminalTextColor
        case .failed: Color.red
        }
    }

    private func connectorColor(for status: StageStatus) -> Color {
        switch status {
        case .completed: Color.green.opacity(0.6)
        case .failed: Color.red.opacity(0.6)
        default: Color.secondary.opacity(0.25)
        }
    }

    private func logLineColor(for type: LogLineType) -> Color {
        switch type {
        case .info: Theme.terminalTextDimColor
        case .success: Theme.terminalTextColor
        case .error: Color.red
        }
    }
}

// MARK: - 脉冲圆点

/// 活跃阶段的绿色脉冲圆点动画。
private struct PulsingCircle: View {
    @State private var isPulsing = false

    var body: some View {
        Circle()
            .fill(Color.green)
            .opacity(isPulsing ? 0.4 : 1.0)
            .animation(
                .easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                value: isPulsing
            )
            .onAppear { isPulsing = true }
    }
}
