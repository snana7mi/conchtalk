/// 文件说明：ChatNavigationTitleView，微信风格左对齐导航栏标题组件。
import SwiftUI

/// ChatNavigationTitleView：
/// 显示服务器名称（标题）和连接状态（副标题），用于导航栏 topBarLeading 位置。
struct ChatNavigationTitleView: View {
    let title: String
    let isConnected: Bool
    let isReconnecting: Bool
    let countryCode: String?
    let presentationState: DirectModePresentationState

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if presentationState.isActive {
                    Text("DIRECT")
                        .font(.caption2.weight(.bold))
                        .kerning(0.6)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(presentationState.modeColors.accentColor.opacity(0.18))
                        .clipShape(Capsule())
                        .foregroundStyle(presentationState.modeColors.accentColor)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }

                Text(title)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
            }
            HStack(spacing: 4) {
                Circle()
                    .fill(Self.statusColor(
                        isConnected: isConnected,
                        isReconnecting: isReconnecting,
                        presentationState: presentationState
                    ))
                    .frame(width: 8, height: 8)
                Text(Self.subtitleText(
                    isConnected: isConnected,
                    isReconnecting: isReconnecting,
                    countryCode: countryCode,
                    presentationState: presentationState
                ))
                    .font(.caption)
                    .foregroundStyle(Self.statusColor(
                        isConnected: isConnected,
                        isReconnecting: isReconnecting,
                        presentationState: presentationState
                    ))
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .animation(.easeInOut(duration: 0.2), value: isConnected)
        .animation(.easeInOut(duration: 0.2), value: isReconnecting)
        .animation(.spring(response: 0.28, dampingFraction: 0.82), value: presentationState)
    }

    // MARK: - 静态逻辑（便于测试）

    /// 根据连接状态和模式生成副标题文字。
    static func subtitleText(
        isConnected: Bool,
        isReconnecting: Bool,
        countryCode: String?,
        presentationState: DirectModePresentationState
    ) -> String {
        if presentationState.isActive, let agentName = presentationState.agentName {
            if isReconnecting {
                return String(localized: "Reconnecting…", bundle: LanguageSettings.currentBundle)
            }
            switch presentationState.statusBar.status {
            case .connecting:
                return String(localized: "Connecting to \(agentName)…", bundle: LanguageSettings.currentBundle)
            case .connected:
                return String(localized: "\(agentName) connected", bundle: LanguageSettings.currentBundle)
            case .executing:
                return String(localized: "\(agentName) working…", bundle: LanguageSettings.currentBundle)
            case .disconnecting:
                return String(localized: "Leaving \(agentName)…", bundle: LanguageSettings.currentBundle)
            case .failed:
                return String(localized: "\(agentName) unavailable", bundle: LanguageSettings.currentBundle)
            case .inactive:
                break
            }
            if !isConnected {
                return String(localized: "Disconnected", bundle: LanguageSettings.currentBundle)
            }
        }

        if isReconnecting {
            return String(localized: "Reconnecting…", bundle: LanguageSettings.currentBundle)
        }
        if !isConnected {
            return String(localized: "Disconnected", bundle: LanguageSettings.currentBundle)
        }

        // 已连接：尝试拼接地理位置
        let connectedText = String(localized: "Connected", bundle: LanguageSettings.currentBundle)
        if let code = countryCode,
           let country = LanguageSettings.currentLocale.localizedString(forRegionCode: code) {
            return "\(country) · \(connectedText)"
        }
        return connectedText
    }

    static func subtitleText(
        isConnected: Bool,
        isReconnecting: Bool,
        countryCode: String?,
        chatMode: ChatMode
    ) -> String {
        if isReconnecting {
            return String(localized: "Reconnecting…", bundle: LanguageSettings.currentBundle)
        }
        if case .directAgent = chatMode, !isConnected {
            return String(localized: "Disconnected", bundle: LanguageSettings.currentBundle)
        }
        return subtitleText(
            isConnected: isConnected,
            isReconnecting: isReconnecting,
            countryCode: countryCode,
            presentationState: legacyPresentationState(for: chatMode)
        )
    }

    /// 根据连接状态返回指示器颜色。
    static func statusColor(
        isConnected: Bool,
        isReconnecting: Bool,
        presentationState: DirectModePresentationState
    ) -> Color {
        if isReconnecting { return .orange }
        if presentationState.isActive {
            switch presentationState.statusBar.status {
            case .connecting:
                return presentationState.modeColors.accentColor.opacity(0.85)
            case .connected:
                return presentationState.modeColors.accentColor
            case .executing:
                return presentationState.modeColors.accentColor
            case .disconnecting:
                return .secondary
            case .failed:
                return .red
            case .inactive:
                break
            }
        }
        if isConnected { return .green }
        return .secondary
    }

    static func statusColor(isConnected: Bool, isReconnecting: Bool) -> Color {
        statusColor(
            isConnected: isConnected,
            isReconnecting: isReconnecting,
            presentationState: legacyPresentationState(for: .normal)
        )
    }

    private static func legacyPresentationState(for chatMode: ChatMode) -> DirectModePresentationState {
        let agent: DirectModePresentationState.AgentIdentity?
        let statusBar: DirectModePresentationState.StatusBar
        let inputBar: DirectModePresentationState.InputBarState

        switch chatMode {
        case .normal:
            agent = nil
            statusBar = .init(title: .app, status: .inactive, marker: .normal)
            inputBar = .init(mode: .normal, placeholder: .none, isEnabled: false, showsCancel: false)
        case .directAgent(let agentName, let agentType):
            agent = .init(name: agentName, type: agentType)
            statusBar = .init(title: .agent(name: agentName), status: .connected, marker: .direct)
            inputBar = .init(mode: .direct, placeholder: .directAgent(name: agentName), isEnabled: true, showsCancel: false)
        }

        return DirectModePresentationState(
            modeState: agent == nil ? .inactive : .active,
            agent: agent,
            themeTokens: .init(
                paletteKey: agent.map { "direct.\($0.type.rawValue)" } ?? "normal",
                accentKey: agent.map { "agent.\($0.type.rawValue)" } ?? "conchtalk",
                markerStyle: agent == nil ? "normal" : "direct"
            ),
            statusBar: statusBar,
            inputBar: inputBar,
            isExecuting: false,
            transition: .none
        )
    }
}
