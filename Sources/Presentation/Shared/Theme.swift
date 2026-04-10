/// 文件说明：Theme，提供跨页面复用的主题与样式能力。
import SwiftUI

/// Theme：定义应用可用的主题样式。
enum Theme {
    // Colors
    static let primaryColor = Color("AccentColor")
    static let userBubbleColor = Color.blue
    static let assistantBubbleColor = Color.secondary.opacity(0.15)
    static let commandBubbleColor = Color.secondary.opacity(0.1)
    static let systemMessageColor = Color.secondary.opacity(0.3)
    static let destructiveColor = Color.red
    static let safeColor = Color.green
    static let reasoningBubbleColor = Color.purple.opacity(0.05)
    static let deniedBubbleColor = Color.red.opacity(0.1)

    // Terminal
    static let terminalBackground = Color(white: 0.08)
    static let terminalTextColor = Color.green
    static let terminalTextDimColor = Color.green.opacity(0.6)
    static let terminalFont = Font.system(.caption, design: .monospaced)

    // Fonts
    static let messageFont = Font.body
    static let commandFont = Font.system(.callout, design: .monospaced)
    static let captionFont = Font.caption
    static let titleFont = Font.headline

    // Spacing
    static let bubblePadding: CGFloat = 12
    static let bubbleCornerRadius: CGFloat = 16
    static let messageSpacing: CGFloat = 8
    static let screenPadding: CGFloat = 16

    // MARK: - 模式颜色集

    /// ModeColors：某种聊天模式下的完整颜色方案。
    struct ModeColors {
        let navBackground: Color
        let navBorder: Color
        let chatBackground: Color
        let agentBubbleColor: Color
        let userBubbleColor: Color
        let accentColor: Color
        let inputBackground: Color
        let agentAvatarGradient: [Color]
        /// 气泡内文字颜色（正常模式用 .primary 跟随系统，直连模式用 .white 保证可读性）。
        let bubbleTextColor: Color
    }

    /// 正常模式颜色（蓝紫色系，与现有风格一致）。
    static let normalMode = ModeColors(
        navBackground: Color(white: 0.1),
        navBorder: Color.secondary.opacity(0.2),
        chatBackground: Color(white: 0.06),
        agentBubbleColor: Color.secondary.opacity(0.15),
        userBubbleColor: Color.blue,
        accentColor: Color.blue,
        inputBackground: Color.secondary.opacity(0.1),
        agentAvatarGradient: [.blue, .cyan],
        bubbleTextColor: .primary
    )

    /// 根据 AgentType 返回对应的直连模式颜色方案。
    /// 每个 agent 有独属的品牌色系，背景由 DirectModeBackground 提供。
    static func directMode(for agentType: AgentType) -> ModeColors {
        switch agentType {
        case .opencode:
            // 绿色系（保持原有风格）
            return ModeColors(
                navBackground: Color.white.opacity(0.15),
                navBorder: Color.white.opacity(0.25),
                chatBackground: Color.clear,
                agentBubbleColor: Color.white.opacity(0.25),
                userBubbleColor: Color(red: 0.0, green: 0.35, blue: 0.18),
                accentColor: Color(red: 0.0, green: 0.35, blue: 0.18),
                inputBackground: Color.white.opacity(0.2),
                agentAvatarGradient: [Color(red: 0.0, green: 0.40, blue: 0.22), Color(red: 0.0, green: 0.55, blue: 0.32)],
                bubbleTextColor: .white
            )
        case .gemini:
            // 蓝紫多色系（Google Gemini 四色 sparkle）
            return ModeColors(
                navBackground: Color.white.opacity(0.15),
                navBorder: Color.white.opacity(0.25),
                chatBackground: Color.clear,
                agentBubbleColor: Color.white.opacity(0.25),
                userBubbleColor: Color(red: 0.25, green: 0.18, blue: 0.50),
                accentColor: Color(red: 0.25, green: 0.18, blue: 0.50),
                inputBackground: Color.white.opacity(0.2),
                agentAvatarGradient: [Color(red: 0.30, green: 0.45, blue: 0.90), Color(red: 0.55, green: 0.28, blue: 0.78)],
                bubbleTextColor: .white
            )
        case .kimi:
            // 深蓝夜空系（月之暗面）
            return ModeColors(
                navBackground: Color.white.opacity(0.15),
                navBorder: Color.white.opacity(0.25),
                chatBackground: Color.clear,
                agentBubbleColor: Color.white.opacity(0.25),
                userBubbleColor: Color(red: 0.06, green: 0.08, blue: 0.22),
                accentColor: Color(red: 0.15, green: 0.20, blue: 0.45),
                inputBackground: Color.white.opacity(0.2),
                agentAvatarGradient: [Color(red: 0.10, green: 0.15, blue: 0.40), Color(red: 0.05, green: 0.08, blue: 0.25)],
                bubbleTextColor: .white
            )
        case .openclaw:
            // 龙虾红系（OpenClaw 红色龙虾）
            return ModeColors(
                navBackground: Color.white.opacity(0.15),
                navBorder: Color.white.opacity(0.25),
                chatBackground: Color.clear,
                agentBubbleColor: Color.white.opacity(0.25),
                userBubbleColor: Color(red: 0.50, green: 0.10, blue: 0.08),
                accentColor: Color(red: 0.50, green: 0.10, blue: 0.08),
                inputBackground: Color.white.opacity(0.2),
                agentAvatarGradient: [Color(red: 0.90, green: 0.22, blue: 0.20), Color(red: 0.68, green: 0.10, blue: 0.10)],
                bubbleTextColor: .white
            )
        case .qwen:
            // 紫色系（通义千问品牌色）
            return ModeColors(
                navBackground: Color.white.opacity(0.15),
                navBorder: Color.white.opacity(0.25),
                chatBackground: Color.clear,
                agentBubbleColor: Color.white.opacity(0.25),
                userBubbleColor: Color(red: 0.28, green: 0.12, blue: 0.45),
                accentColor: Color(red: 0.28, green: 0.12, blue: 0.45),
                inputBackground: Color.white.opacity(0.2),
                agentAvatarGradient: [Color(red: 0.45, green: 0.22, blue: 0.78), Color(red: 0.55, green: 0.30, blue: 0.88)],
                bubbleTextColor: .white
            )
        case .claude:
            // 暖橙棕系（Anthropic 品牌色调）
            return ModeColors(
                navBackground: Color.white.opacity(0.15),
                navBorder: Color.white.opacity(0.25),
                chatBackground: Color.clear,
                agentBubbleColor: Color.white.opacity(0.25),
                userBubbleColor: Color(red: 0.45, green: 0.25, blue: 0.12),
                accentColor: Color(red: 0.45, green: 0.25, blue: 0.12),
                inputBackground: Color.white.opacity(0.2),
                agentAvatarGradient: [Color(red: 0.75, green: 0.45, blue: 0.28), Color(red: 0.85, green: 0.55, blue: 0.35)],
                bubbleTextColor: .white
            )
        case .codex:
            // 深绿系（OpenAI 品牌色调）
            return ModeColors(
                navBackground: Color.white.opacity(0.15),
                navBorder: Color.white.opacity(0.25),
                chatBackground: Color.clear,
                agentBubbleColor: Color.white.opacity(0.25),
                userBubbleColor: Color(red: 0.05, green: 0.35, blue: 0.22),
                accentColor: Color(red: 0.05, green: 0.35, blue: 0.22),
                inputBackground: Color.white.opacity(0.2),
                agentAvatarGradient: [Color(red: 0.08, green: 0.55, blue: 0.38), Color(red: 0.10, green: 0.65, blue: 0.45)],
                bubbleTextColor: .white
            )
        case .cline:
            // 深灰蓝系（Cline 品牌色）
            return ModeColors(
                navBackground: Color.white.opacity(0.15),
                navBorder: Color.white.opacity(0.25),
                chatBackground: Color.clear,
                agentBubbleColor: Color.white.opacity(0.25),
                userBubbleColor: Color(red: 0.20, green: 0.23, blue: 0.26),
                accentColor: Color(red: 0.20, green: 0.23, blue: 0.26),
                inputBackground: Color.white.opacity(0.2),
                agentAvatarGradient: [Color(red: 0.25, green: 0.30, blue: 0.35), Color(red: 0.35, green: 0.40, blue: 0.45)],
                bubbleTextColor: .white
            )
        case .cursor:
            // 黑白系（Cursor 品牌色）
            return ModeColors(
                navBackground: Color.white.opacity(0.15),
                navBorder: Color.white.opacity(0.25),
                chatBackground: Color.clear,
                agentBubbleColor: Color.white.opacity(0.25),
                userBubbleColor: Color(red: 0.10, green: 0.10, blue: 0.12),
                accentColor: Color(red: 0.10, green: 0.10, blue: 0.12),
                inputBackground: Color.white.opacity(0.2),
                agentAvatarGradient: [Color(red: 0.15, green: 0.15, blue: 0.18), Color(red: 0.25, green: 0.25, blue: 0.30)],
                bubbleTextColor: .white
            )
        case .githubCopilot:
            // 蓝灰系（GitHub 品牌色）
            return ModeColors(
                navBackground: Color.white.opacity(0.15),
                navBorder: Color.white.opacity(0.25),
                chatBackground: Color.clear,
                agentBubbleColor: Color.white.opacity(0.25),
                userBubbleColor: Color(red: 0.08, green: 0.12, blue: 0.18),
                accentColor: Color(red: 0.08, green: 0.12, blue: 0.18),
                inputBackground: Color.white.opacity(0.2),
                agentAvatarGradient: [Color(red: 0.15, green: 0.22, blue: 0.35), Color(red: 0.20, green: 0.30, blue: 0.45)],
                bubbleTextColor: .white
            )
        case .goose:
            // 暖白系（Goose by Block）
            return ModeColors(
                navBackground: Color.white.opacity(0.15),
                navBorder: Color.white.opacity(0.25),
                chatBackground: Color.clear,
                agentBubbleColor: Color.white.opacity(0.25),
                userBubbleColor: Color(red: 0.35, green: 0.30, blue: 0.22),
                accentColor: Color(red: 0.35, green: 0.30, blue: 0.22),
                inputBackground: Color.white.opacity(0.2),
                agentAvatarGradient: [Color(red: 0.55, green: 0.48, blue: 0.35), Color(red: 0.65, green: 0.58, blue: 0.42)],
                bubbleTextColor: .white
            )
        case .junie:
            // 亮绿系（JetBrains Junie 品牌色）
            return ModeColors(
                navBackground: Color.white.opacity(0.15),
                navBorder: Color.white.opacity(0.25),
                chatBackground: Color.clear,
                agentBubbleColor: Color.white.opacity(0.25),
                userBubbleColor: Color(red: 0.10, green: 0.38, blue: 0.15),
                accentColor: Color(red: 0.28, green: 0.88, blue: 0.33),
                inputBackground: Color.white.opacity(0.2),
                agentAvatarGradient: [Color(red: 0.20, green: 0.75, blue: 0.28), Color(red: 0.28, green: 0.88, blue: 0.33)],
                bubbleTextColor: .white
            )
        case .kiroCli:
            // 橙黄系（Kiro 品牌色）
            return ModeColors(
                navBackground: Color.white.opacity(0.15),
                navBorder: Color.white.opacity(0.25),
                chatBackground: Color.clear,
                agentBubbleColor: Color.white.opacity(0.25),
                userBubbleColor: Color(red: 0.48, green: 0.30, blue: 0.08),
                accentColor: Color(red: 0.95, green: 0.55, blue: 0.15),
                inputBackground: Color.white.opacity(0.2),
                agentAvatarGradient: [Color(red: 0.90, green: 0.50, blue: 0.12), Color(red: 0.95, green: 0.65, blue: 0.20)],
                bubbleTextColor: .white
            )
        case .openhands:
            // 深灰系（OpenHands 品牌色）
            return ModeColors(
                navBackground: Color.white.opacity(0.15),
                navBorder: Color.white.opacity(0.25),
                chatBackground: Color.clear,
                agentBubbleColor: Color.white.opacity(0.25),
                userBubbleColor: Color(red: 0.09, green: 0.09, blue: 0.09),
                accentColor: Color(red: 0.40, green: 0.40, blue: 0.45),
                inputBackground: Color.white.opacity(0.2),
                agentAvatarGradient: [Color(red: 0.20, green: 0.20, blue: 0.22), Color(red: 0.30, green: 0.30, blue: 0.35)],
                bubbleTextColor: .white
            )
        case .auggie:
            // 紫蓝系（Augment Code 品牌色）
            return ModeColors(
                navBackground: Color.white.opacity(0.15),
                navBorder: Color.white.opacity(0.25),
                chatBackground: Color.clear,
                agentBubbleColor: Color.white.opacity(0.25),
                userBubbleColor: Color(red: 0.35, green: 0.20, blue: 0.65),
                accentColor: Color(red: 0.35, green: 0.20, blue: 0.90),
                inputBackground: Color.white.opacity(0.2),
                agentAvatarGradient: [Color(red: 0.40, green: 0.25, blue: 0.80), Color(red: 0.50, green: 0.30, blue: 0.90)],
                bubbleTextColor: .white
            )
        case .autodev:
            // 蓝色系（AutoDev 品牌色）
            return ModeColors(
                navBackground: Color.white.opacity(0.15),
                navBorder: Color.white.opacity(0.25),
                chatBackground: Color.clear,
                agentBubbleColor: Color.white.opacity(0.25),
                userBubbleColor: Color(red: 0.12, green: 0.30, blue: 0.55),
                accentColor: Color(red: 0.18, green: 0.50, blue: 0.92),
                inputBackground: Color.white.opacity(0.2),
                agentAvatarGradient: [Color(red: 0.15, green: 0.40, blue: 0.80), Color(red: 0.22, green: 0.55, blue: 0.92)],
                bubbleTextColor: .white
            )
        case .blackbox:
            // 黑绿系（Blackbox AI 品牌色）
            return ModeColors(
                navBackground: Color.white.opacity(0.15),
                navBorder: Color.white.opacity(0.25),
                chatBackground: Color.clear,
                agentBubbleColor: Color.white.opacity(0.25),
                userBubbleColor: Color(red: 0.05, green: 0.10, blue: 0.05),
                accentColor: Color(red: 0.0, green: 0.85, blue: 0.0),
                inputBackground: Color.white.opacity(0.2),
                agentAvatarGradient: [Color(red: 0.0, green: 0.60, blue: 0.0), Color(red: 0.0, green: 0.85, blue: 0.0)],
                bubbleTextColor: .white
            )
        case .codeAssistant:
            // 蓝灰系（Code Assistant）
            return ModeColors(
                navBackground: Color.white.opacity(0.15),
                navBorder: Color.white.opacity(0.25),
                chatBackground: Color.clear,
                agentBubbleColor: Color.white.opacity(0.25),
                userBubbleColor: Color(red: 0.15, green: 0.28, blue: 0.45),
                accentColor: Color(red: 0.20, green: 0.40, blue: 0.65),
                inputBackground: Color.white.opacity(0.2),
                agentAvatarGradient: [Color(red: 0.18, green: 0.35, blue: 0.58), Color(red: 0.25, green: 0.45, blue: 0.70)],
                bubbleTextColor: .white
            )
        case .cagent:
            // Docker 蓝系
            return ModeColors(
                navBackground: Color.white.opacity(0.15),
                navBorder: Color.white.opacity(0.25),
                chatBackground: Color.clear,
                agentBubbleColor: Color.white.opacity(0.25),
                userBubbleColor: Color(red: 0.08, green: 0.30, blue: 0.55),
                accentColor: Color(red: 0.10, green: 0.46, blue: 0.82),
                inputBackground: Color.white.opacity(0.2),
                agentAvatarGradient: [Color(red: 0.08, green: 0.40, blue: 0.72), Color(red: 0.12, green: 0.52, blue: 0.88)],
                bubbleTextColor: .white
            )
        case .fastAgentAcp:
            // 橙色系（fast-agent）
            return ModeColors(
                navBackground: Color.white.opacity(0.15),
                navBorder: Color.white.opacity(0.25),
                chatBackground: Color.clear,
                agentBubbleColor: Color.white.opacity(0.25),
                userBubbleColor: Color(red: 0.50, green: 0.30, blue: 0.08),
                accentColor: Color(red: 0.90, green: 0.55, blue: 0.10),
                inputBackground: Color.white.opacity(0.2),
                agentAvatarGradient: [Color(red: 0.85, green: 0.50, blue: 0.08), Color(red: 0.95, green: 0.60, blue: 0.15)],
                bubbleTextColor: .white
            )
        case .droid:
            // 紫色系（Factory Droid）
            return ModeColors(
                navBackground: Color.white.opacity(0.15),
                navBorder: Color.white.opacity(0.25),
                chatBackground: Color.clear,
                agentBubbleColor: Color.white.opacity(0.25),
                userBubbleColor: Color(red: 0.32, green: 0.15, blue: 0.50),
                accentColor: Color(red: 0.55, green: 0.25, blue: 0.85),
                inputBackground: Color.white.opacity(0.2),
                agentAvatarGradient: [Color(red: 0.48, green: 0.20, blue: 0.75), Color(red: 0.60, green: 0.30, blue: 0.88)],
                bubbleTextColor: .white
            )
        case .fount:
            // 绿色系（fount）
            return ModeColors(
                navBackground: Color.white.opacity(0.15),
                navBorder: Color.white.opacity(0.25),
                chatBackground: Color.clear,
                agentBubbleColor: Color.white.opacity(0.25),
                userBubbleColor: Color(red: 0.15, green: 0.38, blue: 0.25),
                accentColor: Color(red: 0.30, green: 0.65, blue: 0.45),
                inputBackground: Color.white.opacity(0.2),
                agentAvatarGradient: [Color(red: 0.25, green: 0.55, blue: 0.38), Color(red: 0.35, green: 0.70, blue: 0.50)],
                bubbleTextColor: .white
            )
        case .mcode:
            // 青绿系（Minion Code）
            return ModeColors(
                navBackground: Color.white.opacity(0.15),
                navBorder: Color.white.opacity(0.25),
                chatBackground: Color.clear,
                agentBubbleColor: Color.white.opacity(0.25),
                userBubbleColor: Color(red: 0.12, green: 0.35, blue: 0.30),
                accentColor: Color(red: 0.22, green: 0.62, blue: 0.52),
                inputBackground: Color.white.opacity(0.2),
                agentAvatarGradient: [Color(red: 0.18, green: 0.52, blue: 0.42), Color(red: 0.28, green: 0.68, blue: 0.58)],
                bubbleTextColor: .white
            )
        case .vibe:
            // 橘红系（Mistral Vibe 品牌色）
            return ModeColors(
                navBackground: Color.white.opacity(0.15),
                navBorder: Color.white.opacity(0.25),
                chatBackground: Color.clear,
                agentBubbleColor: Color.white.opacity(0.25),
                userBubbleColor: Color(red: 0.55, green: 0.22, blue: 0.05),
                accentColor: Color(red: 0.98, green: 0.32, blue: 0.06),
                inputBackground: Color.white.opacity(0.2),
                agentAvatarGradient: [Color(red: 0.92, green: 0.35, blue: 0.08), Color(red: 0.98, green: 0.48, blue: 0.12)],
                bubbleTextColor: .white
            )
        case .qodercli:
            // 酒红系（Qoder CLI）
            return ModeColors(
                navBackground: Color.white.opacity(0.15),
                navBorder: Color.white.opacity(0.25),
                chatBackground: Color.clear,
                agentBubbleColor: Color.white.opacity(0.25),
                userBubbleColor: Color(red: 0.40, green: 0.12, blue: 0.20),
                accentColor: Color(red: 0.65, green: 0.20, blue: 0.35),
                inputBackground: Color.white.opacity(0.2),
                agentAvatarGradient: [Color(red: 0.55, green: 0.15, blue: 0.28), Color(red: 0.72, green: 0.22, blue: 0.38)],
                bubbleTextColor: .white
            )
        case .stakpak:
            // 深蓝冷光系（Stakpak）
            return ModeColors(
                navBackground: Color.white.opacity(0.15),
                navBorder: Color.white.opacity(0.25),
                chatBackground: Color.clear,
                agentBubbleColor: Color.white.opacity(0.25),
                userBubbleColor: Color(red: 0.10, green: 0.10, blue: 0.20),
                accentColor: Color(red: 0.40, green: 0.80, blue: 1.0),
                inputBackground: Color.white.opacity(0.2),
                agentAvatarGradient: [Color(red: 0.12, green: 0.15, blue: 0.30), Color(red: 0.20, green: 0.25, blue: 0.45)],
                bubbleTextColor: .white
            )
        case .vtcode:
            // 冷蓝灰系（VT Code）
            return ModeColors(
                navBackground: Color.white.opacity(0.15),
                navBorder: Color.white.opacity(0.25),
                chatBackground: Color.clear,
                agentBubbleColor: Color.white.opacity(0.25),
                userBubbleColor: Color(red: 0.12, green: 0.12, blue: 0.16),
                accentColor: Color(red: 0.70, green: 0.85, blue: 1.0),
                inputBackground: Color.white.opacity(0.2),
                agentAvatarGradient: [Color(red: 0.15, green: 0.18, blue: 0.25), Color(red: 0.22, green: 0.28, blue: 0.38)],
                bubbleTextColor: .white
            )
        case .agentpool:
            // 蓝灰系（AgentPool）
            return ModeColors(
                navBackground: Color.white.opacity(0.15),
                navBorder: Color.white.opacity(0.25),
                chatBackground: Color.clear,
                agentBubbleColor: Color.white.opacity(0.25),
                userBubbleColor: Color(red: 0.15, green: 0.22, blue: 0.35),
                accentColor: Color(red: 0.25, green: 0.35, blue: 0.55),
                inputBackground: Color.white.opacity(0.2),
                agentAvatarGradient: [Color(red: 0.20, green: 0.30, blue: 0.48), Color(red: 0.30, green: 0.40, blue: 0.60)],
                bubbleTextColor: .white
            )
        case .codebuddy:
            // 亮蓝系（CodeBuddy 品牌色）
            return ModeColors(
                navBackground: Color.white.opacity(0.15),
                navBorder: Color.white.opacity(0.25),
                chatBackground: Color.clear,
                agentBubbleColor: Color.white.opacity(0.25),
                userBubbleColor: Color(red: 0.15, green: 0.42, blue: 0.72),
                accentColor: Color(red: 0.20, green: 0.55, blue: 0.90),
                inputBackground: Color.white.opacity(0.2),
                agentAvatarGradient: [Color(red: 0.18, green: 0.48, blue: 0.82), Color(red: 0.25, green: 0.60, blue: 0.95)],
                bubbleTextColor: .white
            )
        }
    }
}
