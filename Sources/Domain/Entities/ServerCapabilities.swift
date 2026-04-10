/// 文件说明：ServerCapabilities，描述远端服务器探测到的可用工具与特性。
import Foundation

/// ServerCapabilities：
/// 在 SSH 连接建立后通过探测命令检测远端服务器的工具可用性，
/// 供长时间任务管理等功能选择最优执行策略。
nonisolated struct ServerCapabilities: Sendable {
    /// 远端可用的编码代理列表。
    var availableAgents: [AgentInfo] = []
    /// 代理探测是否已完成。未完成时不应据此过滤工具定义。
    var agentDetectionCompleted: Bool = false

    /// 未探测时的默认值（保守策略：均不可用，但不过滤工具）。
    static let unknown = ServerCapabilities()
}

/// AgentInfo：远端服务器上可用的编码代理信息。
nonisolated struct AgentInfo: Sendable, Codable, Hashable {
    let type: AgentType
    let path: String
    let version: String?
    /// 需要外部包装器的代理使用此字段覆盖默认 acpCommand。
    let wrapperCommand: String?

    init(type: AgentType, path: String, version: String?, wrapperCommand: String? = nil) {
        self.type = type
        self.path = path
        self.version = version
        self.wrapperCommand = wrapperCommand
    }

    /// 构造启动代理的 ACP 命令。
    /// - wrapperCommand 非空时优先使用。
    /// - openclaw 的 ACP 模式是 Gateway 桥接器，需要 `--session` 指定已有的 Gateway session key，
    ///   否则自动生成的 `acp:<uuid>` key 缺少 ACP 元数据导致 ACP_SESSION_INIT_FAILED。
    var acpCommand: String {
        if let wrapperCommand {
            return wrapperCommand
        }
        switch type {
        case .openclaw:
            return "\(path) \(type.acpFlag) --session agent:main:main --reset-session"
        default:
            return "\(path) \(type.acpFlag)"
        }
    }
}

/// AgentType：支持的编码代理类型。
///
/// 新增代理只需：
/// 1. 添加 case
/// 2. 填充下方各计算属性（acpFlag, displayName, systemIcon）
/// 3. 在 Theme.directMode(for:) 中补充颜色
/// CaseIterable 自动将新 case 纳入探测和 UI 展示。
nonisolated enum AgentType: String, Sendable, Codable, Hashable, CaseIterable {
    case opencode
    case gemini
    case kimi
    case openclaw
    case qwen
    case claude
    case codex
    // ACP 原生支持的代理
    case cline
    case cursor
    case goose
    case junie
    case openhands
    case auggie
    case autodev
    case blackbox
    case cagent
    case droid
    case fount
    case mcode
    case qodercli
    case stakpak
    case vtcode
    case agentpool
    case vibe
    case codebuddy
    // 需要特殊二进制名的代理
    case githubCopilot = "github-copilot"
    case kiroCli = "kiro-cli"
    case codeAssistant = "code-assistant"
    case fastAgentAcp = "fast-agent-acp"

    // MARK: - 元数据

    /// AgentTypeMetadata：每个 AgentType 的静态属性集合，避免多个 computed property 各自 switch。
    private struct Metadata {
        let isCodingAgent: Bool
        let acpFlag: String
        let displayName: String
        let systemIcon: String?
        let iconEmoji: String?
        let logoAssetName: String
    }

    /// 所有 AgentType 的元数据查表。新增 case 时只需在此处添加一行。
    private static let metadataTable: [AgentType: Metadata] = [
        // 现有代理
        .opencode:      Metadata(isCodingAgent: true,  acpFlag: "acp",   displayName: "OpenCode",        systemIcon: "chevron.left.forwardslash.chevron.right", iconEmoji: nil,    logoAssetName: "logo-opencode"),
        .gemini:        Metadata(isCodingAgent: true,  acpFlag: "--acp", displayName: "Gemini CLI",       systemIcon: "sparkles",                iconEmoji: nil,    logoAssetName: "logo-gemini"),
        .kimi:          Metadata(isCodingAgent: true,  acpFlag: "acp",   displayName: "Kimi CLI",         systemIcon: "moon.stars",              iconEmoji: nil,    logoAssetName: "logo-kimi"),
        .openclaw:      Metadata(isCodingAgent: false, acpFlag: "acp",   displayName: "OpenClaw",         systemIcon: nil,                       iconEmoji: "🦞",  logoAssetName: "logo-openclaw"),
        .qwen:          Metadata(isCodingAgent: true,  acpFlag: "--acp", displayName: "Qwen Code",        systemIcon: "questionmark.bubble",      iconEmoji: nil,    logoAssetName: "logo-qwen"),
        .claude:        Metadata(isCodingAgent: true,  acpFlag: "",      displayName: "Claude Code",      systemIcon: "brain",                   iconEmoji: nil,    logoAssetName: "logo-claude"),
        .codex:         Metadata(isCodingAgent: true,  acpFlag: "",      displayName: "Codex",            systemIcon: "cube",                    iconEmoji: nil,    logoAssetName: "logo-codex"),
        // ACP 原生支持的代理
        .cline:         Metadata(isCodingAgent: true,  acpFlag: "--acp", displayName: "Cline",            systemIcon: "eye",                     iconEmoji: nil,    logoAssetName: "logo-cline"),
        .cursor:        Metadata(isCodingAgent: true,  acpFlag: "acp",   displayName: "Cursor",           systemIcon: "cursorarrow.rays",        iconEmoji: nil,    logoAssetName: "logo-cursor"),
        .githubCopilot: Metadata(isCodingAgent: true,  acpFlag: "--acp", displayName: "GitHub Copilot",   systemIcon: "airplane",                iconEmoji: nil,    logoAssetName: "logo-github-copilot"),
        .goose:         Metadata(isCodingAgent: true,  acpFlag: "acp",   displayName: "Goose",            systemIcon: "bird",                    iconEmoji: nil,    logoAssetName: "logo-goose"),
        .junie:         Metadata(isCodingAgent: true,  acpFlag: "acp",   displayName: "Junie",            systemIcon: "hammer",                  iconEmoji: nil,    logoAssetName: "logo-junie"),
        .kiroCli:       Metadata(isCodingAgent: true,  acpFlag: "acp",   displayName: "Kiro CLI",         systemIcon: "bolt.circle",             iconEmoji: nil,    logoAssetName: "logo-kiro"),
        .openhands:     Metadata(isCodingAgent: true,  acpFlag: "acp",   displayName: "OpenHands",        systemIcon: "hand.raised",             iconEmoji: nil,    logoAssetName: "logo-openhands"),
        .auggie:        Metadata(isCodingAgent: true,  acpFlag: "--acp", displayName: "Augment Code",     systemIcon: "plus.magnifyingglass",    iconEmoji: nil,    logoAssetName: "logo-augment"),
        .autodev:       Metadata(isCodingAgent: true,  acpFlag: "--acp", displayName: "AutoDev",          systemIcon: "gearshape.2",             iconEmoji: nil,    logoAssetName: "logo-autodev"),
        .blackbox:      Metadata(isCodingAgent: true,  acpFlag: "--acp", displayName: "Blackbox AI",      systemIcon: "square.fill",             iconEmoji: nil,    logoAssetName: "logo-blackbox"),
        .codeAssistant: Metadata(isCodingAgent: true,  acpFlag: "acp",   displayName: "Code Assistant",   systemIcon: "person.badge.key",        iconEmoji: nil,    logoAssetName: "logo-code-assistant"),
        .cagent:        Metadata(isCodingAgent: true,  acpFlag: "acp",   displayName: "Docker Agent",     systemIcon: "shippingbox",             iconEmoji: nil,    logoAssetName: "logo-cagent"),
        .fastAgentAcp:  Metadata(isCodingAgent: false, acpFlag: "",      displayName: "fast-agent",       systemIcon: "bolt",                    iconEmoji: nil,    logoAssetName: "logo-fast-agent"),
        .droid:         Metadata(isCodingAgent: true,  acpFlag: "acp",   displayName: "Factory Droid",    systemIcon: "cpu",                     iconEmoji: nil,    logoAssetName: "logo-droid"),
        .fount:         Metadata(isCodingAgent: false, acpFlag: "acp",   displayName: "fount",            systemIcon: "drop",                    iconEmoji: nil,    logoAssetName: "logo-fount"),
        .mcode:         Metadata(isCodingAgent: true,  acpFlag: "acp",   displayName: "Minion Code",      systemIcon: "ant",                     iconEmoji: nil,    logoAssetName: "logo-mcode"),
        .vibe:          Metadata(isCodingAgent: true,  acpFlag: "--acp", displayName: "Mistral",          systemIcon: "waveform",                iconEmoji: nil,    logoAssetName: "logo-mistral-vibe"),
        .qodercli:      Metadata(isCodingAgent: true,  acpFlag: "--acp", displayName: "Qoder CLI",        systemIcon: "terminal",                iconEmoji: nil,    logoAssetName: "logo-qoder"),
        .stakpak:       Metadata(isCodingAgent: true,  acpFlag: "acp",   displayName: "Stakpak",          systemIcon: "server.rack",             iconEmoji: nil,    logoAssetName: "logo-stakpak"),
        .vtcode:        Metadata(isCodingAgent: true,  acpFlag: "acp",   displayName: "VT Code",          systemIcon: "text.cursor",             iconEmoji: nil,    logoAssetName: "logo-vtcode"),
        .agentpool:     Metadata(isCodingAgent: false, acpFlag: "serve-acp", displayName: "AgentPool",    systemIcon: "person.3",                iconEmoji: nil,    logoAssetName: "logo-agentpool"),
        .codebuddy:     Metadata(isCodingAgent: true,  acpFlag: "--acp",     displayName: "CodeBuddy",    systemIcon: "ladybug",                 iconEmoji: nil,    logoAssetName: "logo-codebuddy"),
    ]

    /// 获取当前 case 的元数据（metadataTable 覆盖了所有 case，不会 nil）。
    private var metadata: Metadata { Self.metadataTable[self]! }

    // MARK: - 探测相关

    /// 是否为编码代理（需要工作目录选择）。
    /// openclaw 不是编码代理，不需要工作目录选择。
    var isCodingAgent: Bool { metadata.isCodingAgent }

    /// 远端命令行二进制名（用于 `command -v` 探测）。
    /// 默认与 rawValue 一致；若未来有代理二进制名不同于 case 名，可改为 switch。
    var binaryName: String { rawValue }

    /// 启动 ACP 模式的子命令或 flag。
    var acpFlag: String { metadata.acpFlag }

    // MARK: - UI 展示

    /// 用户可见的显示名。
    var displayName: String { metadata.displayName }

    /// SF Symbols 图标名（openclaw 无合适 SF Symbol，使用 emoji 替代）。
    var systemIcon: String? { metadata.systemIcon }

    /// Emoji 图标（仅 SF Symbols 无法覆盖的 agent 使用）。
    var iconEmoji: String? { metadata.iconEmoji }

    /// 品牌 Logo 在 xcassets 中的 image set 名称。
    var logoAssetName: String { metadata.logoAssetName }

    /// 根据 displayName 反查 AgentType（用于历史直连消息匹配）。
    static func from(displayName: String) -> AgentType? {
        let normalizedInput = normalizedAgentName(displayName)
        guard !normalizedInput.isEmpty else { return nil }

        return allCases.first { agentType in
            let display = normalizedAgentName(agentType.displayName)
            let raw = normalizedAgentName(agentType.rawValue)
            return normalizedInput == display
                || normalizedInput == raw
                || normalizedInput.hasPrefix(display)
                || normalizedInput.hasPrefix(raw)
                || normalizedInput.contains(display)
                || normalizedInput.contains(raw)
        }
    }

    private static func normalizedAgentName(_ value: String) -> String {
        let scalars = value.lowercased().unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
        }
        return String(String.UnicodeScalarView(scalars))
    }

}
