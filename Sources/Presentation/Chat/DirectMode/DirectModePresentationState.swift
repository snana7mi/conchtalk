/// 文件说明：DirectModePresentationState，封装直连模式 UI 所需的派生展示状态。
import Foundation
@preconcurrency import ACPModel

/// DirectModeLifecycle：直连模式的最小生命周期状态。
enum DirectModeLifecycle: Equatable {
    case idle
    case connecting
    case connected
    case executing
    case disconnecting
    case failed(message: String?)
}

struct DirectModeMetadata {
    var commands: [AvailableCommand] = []
    var models: ModelsInfo?
    var modes: ModesInfo?
    var configOptions: [SessionConfigOption] = []
}

/// DirectModePresentationState：直连模式 UI 的统一展示模型。
struct DirectModePresentationState: Equatable {
    enum ModeState: Equatable {
        case inactive
        case active
    }

    enum TransitionState: Equatable {
        case none
        case entering
        case exiting
    }

    struct AgentIdentity: Equatable {
        let name: String
        let type: AgentType
    }

    struct StatusBar: Equatable {
        enum Title: Equatable {
            case app
            case agent(name: String)
        }

        enum Status: Equatable {
            case inactive
            case connecting
            case connected
            case executing
            case disconnecting
            case failed
        }

        enum Marker: Equatable {
            case normal
            case direct
        }

        let title: Title
        let status: Status
        let marker: Marker
    }

    struct InputBarState: Equatable {
        enum Mode: Equatable {
            case normal
            case direct
        }

        enum Placeholder: Equatable {
            case none
            case directAgent(name: String)
        }

        let mode: Mode
        let placeholder: Placeholder
        let isEnabled: Bool
        let showsCancel: Bool
    }

    struct ThemeTokens: Equatable {
        /// UI 层可用于切换主题资源的稳定 token。
        let paletteKey: String
        let accentKey: String
        let markerStyle: String
    }

    let modeState: ModeState
    let agent: AgentIdentity?
    let themeTokens: ThemeTokens
    let statusBar: StatusBar
    let inputBar: InputBarState
    let isExecuting: Bool
    let transition: TransitionState

    var isActive: Bool {
        modeState == .active
    }

    var chatMode: ChatMode {
        guard let agent else { return .normal }
        return .directAgent(agentName: agent.name, agentType: agent.type)
    }

    var modeColors: Theme.ModeColors {
        guard let agent else { return Theme.normalMode }
        return Theme.directMode(for: agent.type)
    }

    var inputPlaceholderText: String? {
        switch inputBar.placeholder {
        case .none:
            return nil
        case .directAgent(let name):
            return String(localized: "Chat with \(name)...", bundle: LanguageSettings.currentBundle)
        }
    }

    var agentName: String? {
        agent?.name
    }
}

extension DirectModePresentationState {
    /// 从 DirectSessionState 构建展示状态。
    static func build(from state: DirectSessionState) -> DirectModePresentationState {
        let lifecycle = state.lifecycle
        let activeAgent = state.activeAgent

        let modeState: ModeState = lifecycle == .idle ? .inactive : .active
        let isExecuting = lifecycle == .executing

        let canSend = activeAgent != nil && lifecycle == .connected
        let canCancel = activeAgent != nil && lifecycle == .executing

        let status: StatusBar.Status
        switch lifecycle {
        case .idle:
            status = .inactive
        case .connecting:
            status = .connecting
        case .connected:
            status = .connected
        case .executing:
            status = .executing
        case .disconnecting:
            status = .disconnecting
        case .failed:
            status = .failed
        }

        let transition: TransitionState
        switch lifecycle {
        case .connecting:
            transition = .entering
        case .disconnecting:
            transition = .exiting
        default:
            transition = .none
        }

        let placeholder: InputBarState.Placeholder = activeAgent.map { .directAgent(name: $0.name) } ?? .none
        let marker: StatusBar.Marker = modeState == .active ? .direct : .normal
        let title: StatusBar.Title = activeAgent.map { .agent(name: $0.name) } ?? .app
        let themeTokens: ThemeTokens
        if let activeAgent {
            themeTokens = .init(
                paletteKey: "direct.\(activeAgent.type.rawValue)",
                accentKey: "agent.\(activeAgent.type.rawValue)",
                markerStyle: "direct"
            )
        } else {
            themeTokens = .init(
                paletteKey: "normal",
                accentKey: "conchtalk",
                markerStyle: "normal"
            )
        }

        return DirectModePresentationState(
            modeState: modeState,
            agent: activeAgent,
            themeTokens: themeTokens,
            statusBar: .init(title: title, status: status, marker: marker),
            inputBar: .init(
                mode: modeState == .active ? .direct : .normal,
                placeholder: placeholder,
                isEnabled: canSend,
                showsCancel: canCancel
            ),
            isExecuting: isExecuting,
            transition: transition
        )
    }
}
