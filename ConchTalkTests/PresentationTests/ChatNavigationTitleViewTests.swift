/// 文件说明：ChatNavigationTitleViewTests，验证导航栏标题组件的副标题文本与颜色逻辑。
import Foundation
import SwiftUI
import Testing
@testable import ConchTalk

@Suite("ChatNavigationTitleView subtitle logic")
struct ChatNavigationTitleViewTests {

    @Test("直连模式连接中副标题使用 presentation state")
    func directModeConnectingUsesPresentationState() {
        let subtitle = ChatNavigationTitleView.subtitleText(
            isConnected: true,
            isReconnecting: false,
            countryCode: "JP",
            presentationState: DirectModePresentationState(
                modeState: .active,
                agent: .init(name: "Codex", type: .codex),
                themeTokens: .init(
                    paletteKey: "direct.codex",
                    accentKey: "agent.codex",
                    markerStyle: "direct"
                ),
                statusBar: .init(
                    title: .agent(name: "Codex"),
                    status: .connecting,
                    marker: .direct
                ),
                inputBar: .init(
                    mode: .direct,
                    placeholder: .directAgent(name: "Codex"),
                    isEnabled: false,
                    showsCancel: false
                ),
                isExecuting: false,
                transition: .entering
            )
        )

        #expect(subtitle.contains("Codex"))
        #expect(!subtitle.isEmpty)
    }

    @Test("直连模式执行中副标题使用 presentation state")
    func directModeExecutingUsesPresentationState() {
        let subtitle = ChatNavigationTitleView.subtitleText(
            isConnected: true,
            isReconnecting: false,
            countryCode: "JP",
            presentationState: DirectModePresentationState(
                modeState: .active,
                agent: .init(name: "Codex", type: .codex),
                themeTokens: .init(
                    paletteKey: "direct.codex",
                    accentKey: "agent.codex",
                    markerStyle: "direct"
                ),
                statusBar: .init(
                    title: .agent(name: "Codex"),
                    status: .executing,
                    marker: .direct
                ),
                inputBar: .init(
                    mode: .direct,
                    placeholder: .directAgent(name: "Codex"),
                    isEnabled: false,
                    showsCancel: true
                ),
                isExecuting: true,
                transition: .none
            )
        )

        let expected = String(localized: "Codex working…", bundle: LanguageSettings.currentBundle)
        #expect(subtitle == expected)
    }

    @Test("普通模式已连接 - 有地理位置时显示 '位置 · Connected'")
    func normalConnectedWithLocation() {
        let subtitle = ChatNavigationTitleView.subtitleText(
            isConnected: true,
            isReconnecting: false,
            countryCode: "JP",
            chatMode: .normal
        )
        let expectedCountry = Locale.current.localizedString(forRegionCode: "JP") ?? "JP"
        #expect(subtitle.contains(expectedCountry))
    }

    @Test("普通模式已连接 - 无地理位置时只显示 'Connected'")
    func normalConnectedWithoutLocation() {
        let subtitle = ChatNavigationTitleView.subtitleText(
            isConnected: true,
            isReconnecting: false,
            countryCode: nil,
            chatMode: .normal
        )
        #expect(!subtitle.contains("·"))
    }

    @Test("重连中显示重连文本，不含地理位置")
    func reconnecting() {
        let subtitle = ChatNavigationTitleView.subtitleText(
            isConnected: true,
            isReconnecting: true,
            countryCode: "JP",
            chatMode: .normal
        )
        let expectedReconnecting = String(localized: "Reconnecting…", bundle: LanguageSettings.currentBundle)
        #expect(subtitle == expectedReconnecting)
    }

    @Test("已断开显示断开文本，不含地理位置")
    func disconnected() {
        let subtitle = ChatNavigationTitleView.subtitleText(
            isConnected: false,
            isReconnecting: false,
            countryCode: "JP",
            chatMode: .normal
        )
        let expectedDisconnected = String(localized: "Disconnected", bundle: LanguageSettings.currentBundle)
        #expect(subtitle == expectedDisconnected)
    }

    @Test("直连模式已连接显示 agentName connected")
    func directModeConnected() {
        let subtitle = ChatNavigationTitleView.subtitleText(
            isConnected: true,
            isReconnecting: false,
            countryCode: "JP",
            chatMode: .directAgent(agentName: "OpenCode", agentType: .opencode)
        )
        #expect(subtitle.contains("OpenCode"))
    }

    @Test("直连模式断开显示断开文本")
    func directModeDisconnected() {
        let subtitle = ChatNavigationTitleView.subtitleText(
            isConnected: false,
            isReconnecting: false,
            countryCode: "JP",
            chatMode: .directAgent(agentName: "OpenCode", agentType: .opencode)
        )
        #expect(!subtitle.contains("OpenCode"))
        #expect(!subtitle.isEmpty)
    }

    @Test("状态颜色 - 已连接为 green")
    func connectedColorIsGreen() {
        let color = ChatNavigationTitleView.statusColor(
            isConnected: true,
            isReconnecting: false
        )
        #expect(color == .green)
    }

    @Test("状态颜色 - 重连中为 orange")
    func reconnectingColorIsOrange() {
        let color = ChatNavigationTitleView.statusColor(
            isConnected: true,
            isReconnecting: true
        )
        #expect(color == .orange)
    }

    @Test("状态颜色 - 已断开为 secondary")
    func disconnectedColorIsSecondary() {
        let color = ChatNavigationTitleView.statusColor(
            isConnected: false,
            isReconnecting: false
        )
        #expect(color == .secondary)
    }
}
