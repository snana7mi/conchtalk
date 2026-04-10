/// 文件说明：ServerInfoView，服务器信息主页面，组装所有子组件展示完整的服务器状态。

import SwiftUI

/// ServerInfoView：
/// 根据加载状态切换显示，加载完成后以 ScrollView 呈现服务器概览、CPU、内存、磁盘、进程等信息卡片。
struct ServerInfoView: View {
    @State private var viewModel: ServerInfoViewModel
    @State private var pulseAnimation = false

    init(server: Server, sshClient: SSHClientProtocol) {
        _viewModel = State(initialValue: ServerInfoViewModel(server: server, sshClient: sshClient))
    }

    var body: some View {
        Group {
            switch viewModel.loadingState {
            case .loading:
                ProgressView()
            case .unsupported:
                unsupportedView
            case .error(let message):
                errorView(message: message)
            case .disconnected:
                disconnectedView
            case .loaded:
                contentView
            }
        }
        .navigationTitle(String(localized: "Server Info", bundle: LanguageSettings.currentBundle))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await viewModel.startMonitoring()
        }
    }

    // MARK: - 主内容

    private var contentView: some View {
        ScrollView {
            VStack(spacing: 16) {
                serverHeaderCard
                cpuCard
                memoryCard
                diskCard
                processCard
                refreshIndicator
            }
            .padding()
        }
    }

    // MARK: - 服务器概览卡片

    private var serverHeaderCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 图标 + 名称 + 连接信息
            HStack(spacing: 12) {
                serverIcon
                VStack(alignment: .leading, spacing: 2) {
                    Text(viewModel.server.name)
                        .font(.headline)
                    Text("\(viewModel.server.username)@\(viewModel.server.host):\(viewModel.server.port)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Divider()

            // 信息行
            infoRow(
                label: String(localized: "System", bundle: LanguageSettings.currentBundle),
                value: viewModel.data.osVersion
            )
            infoRow(
                label: String(localized: "Hostname", bundle: LanguageSettings.currentBundle),
                value: viewModel.data.hostname
            )
            infoRow(
                label: String(localized: "Uptime", bundle: LanguageSettings.currentBundle),
                value: viewModel.data.uptime
            )
            infoRow(
                label: String(localized: "IP Address", bundle: LanguageSettings.currentBundle),
                value: viewModel.data.ipAddress
            )
        }
        .cardStyle()
    }

    /// 服务器图标：优先显示国旗 emoji，回退到系统图标
    @ViewBuilder
    private var serverIcon: some View {
        let emoji = viewModel.server.flagEmoji
        if emoji != "❓" {
            Text(emoji)
                .font(.title)
                .frame(width: 40, height: 40)
                .background(Color.secondary.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            Image(systemName: "server.rack")
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 40, height: 40)
                .background(Color.secondary.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private func infoRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.caption.weight(.medium))
        }
    }

    // MARK: - CPU 卡片

    private var cpuCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle(String(localized: "CPU", bundle: LanguageSettings.currentBundle))

            if !viewModel.data.cpuModel.isEmpty {
                Text(viewModel.data.cpuModel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(
                String(
                    localized: "\(viewModel.data.coreCount) cores",
                    bundle: LanguageSettings.currentBundle
                )
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible()), count: 4),
                spacing: 8
            ) {
                ForEach(Array(viewModel.data.cpuUsagePerCore.enumerated()), id: \.offset) { index, usage in
                    CpuCoreRingView(coreIndex: index, usage: usage)
                }
            }
        }
        .cardStyle()
    }

    // MARK: - 内存卡片

    private var memoryCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle(String(localized: "Memory", bundle: LanguageSettings.currentBundle))

            MemoryRingView(
                usagePercent: viewModel.data.memoryUsagePercent,
                used: viewModel.data.memoryUsed,
                total: viewModel.data.memoryTotal,
                available: viewModel.data.memoryAvailable
            )
        }
        .cardStyle()
    }

    // MARK: - 磁盘卡片

    private var diskCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle(String(localized: "Disk", bundle: LanguageSettings.currentBundle))

            ForEach(viewModel.data.diskUsages) { disk in
                HStack {
                    Text(disk.mountPoint)
                        .font(.caption.weight(.medium))
                    Spacer()
                    Text("\(disk.used) / \(disk.total)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(disk.percentage)%")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(diskColor(for: disk.percentage))
                }
            }
        }
        .cardStyle()
    }

    /// 磁盘用量颜色
    private func diskColor(for percentage: Int) -> Color {
        switch percentage {
        case ..<50: .green
        case 50..<80: .orange
        default: .red
        }
    }

    // MARK: - 进程卡片

    private var processCard: some View {
        ProcessListView(
            processes: viewModel.data.topProcesses,
            sortMode: $viewModel.processSortMode
        )
        .cardStyle()
    }

    // MARK: - 刷新指示器

    private var refreshIndicator: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(.green)
                .frame(width: 6, height: 6)
                .opacity(pulseAnimation ? 1 : 0.3)
                .animation(.easeInOut(duration: 1).repeatForever(), value: pulseAnimation)
                .onAppear { pulseAnimation = true }

            Text(String(localized: "Auto-refresh every 1s", bundle: LanguageSettings.currentBundle))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 4)
    }

    // MARK: - 状态视图

    private var unsupportedView: some View {
        ContentUnavailableView {
            Label(
                String(localized: "Linux servers only", bundle: LanguageSettings.currentBundle),
                systemImage: "desktopcomputer.trianglebadge.exclamationmark"
            )
        } description: {
            Text(String(
                localized: "Linux servers only",
                bundle: LanguageSettings.currentBundle
            ))
        }
    }

    private func errorView(message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.red)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(String(localized: "Retry", bundle: LanguageSettings.currentBundle)) {
                Task { await viewModel.startMonitoring() }
            }
            .buttonStyle(.bordered)
        }
        .padding()
    }

    private var disconnectedView: some View {
        VStack(spacing: 16) {
            Image(systemName: "wifi.slash")
                .font(.largeTitle)
                .foregroundStyle(.orange)
            Text(String(localized: "Disconnected", bundle: LanguageSettings.currentBundle))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button(String(localized: "Retry", bundle: LanguageSettings.currentBundle)) {
                Task { await viewModel.startMonitoring() }
            }
            .buttonStyle(.bordered)
        }
        .padding()
    }

    // MARK: - 辅助

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }
}

// MARK: - 卡片样式修饰符

private extension View {
    func cardStyle() -> some View {
        self
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
