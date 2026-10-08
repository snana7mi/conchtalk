/// 文件说明：AnthropicModelCapabilities，按 Claude 模型名推断思考模式、输出上限与采样参数限制。
import Foundation

/// Anthropic 思考配置的线上模式。
nonisolated enum AnthropicThinkingMode: String, Sendable, Equatable {
    /// `thinking: {type: "adaptive"}` + `output_config.effort`（Claude 4.6 及之后的模型）。
    case adaptive
    /// `thinking: {type: "enabled", budget_tokens: N}`（Claude 4.5 及更早；4.7+ 会拒绝）。
    case manual
}

/// AnthropicModelCapabilities：
/// 基于官方文档（platform.claude.com，2026-10）对模型名做保守推断。
/// 推断失败（第三方 Anthropic 兼容模型等）时退回最兼容的行为；
/// 遇到 400「不支持该思考模式」时由调用方切换模式重试（见 `thinkingModeFallback(from:)`）。
nonisolated enum AnthropicModelCapabilities {

    /// 解析后的 Claude 模型版本。
    struct Version: Equatable, Sendable {
        var family: String   // opus / sonnet / haiku / fable / mythos
        var major: Int?
        var minor: Int
    }

    /// 解析模型名，兼容 `claude-opus-4-6`、`claude-sonnet-4-5-20250929`、
    /// `us.anthropic.claude-opus-4-7-v1:0`、`claude-3-7-sonnet-20250219`、`claude-mythos-preview` 等写法。
    static func version(of model: String) -> Version? {
        let lower = model.lowercased()
        // 新命名：claude-<family>-<major>[-<minor>]
        if let match = lower.firstMatch(of: /claude-(opus|sonnet|haiku|fable|mythos)(?:-(\d+)(?:[-.](\d{1,2}))?)?(?![0-9])/) {
            let family = String(match.1)
            let major = match.2.flatMap { Int($0) }
            let minor = match.3.flatMap { Int($0) } ?? 0
            // 日期后缀（如 -20250514）不会被当作 minor：\d{1,2} 后紧跟数字时整组不匹配
            return Version(family: family, major: major, minor: minor)
        }
        // 旧命名：claude-<major>-<minor>-<family> / claude-<major>-<family>
        if let match = lower.firstMatch(of: /claude-(\d)(?:-(\d))?-(opus|sonnet|haiku)/) {
            return Version(family: String(match.3), major: Int(match.1), minor: match.2.flatMap { Int($0) } ?? 0)
        }
        return nil
    }

    /// 版本号是否 ≥ major.minor（未知版本号的 fable / mythos 视为最新一代）。
    private static func isAtLeast(_ version: Version, _ major: Int, _ minor: Int) -> Bool {
        guard let vMajor = version.major else {
            return version.family == "fable" || version.family == "mythos"
        }
        if vMajor != major { return vMajor > major }
        return version.minor >= minor
    }

    /// 推荐的思考模式：Claude 4.6+ / 5.x / Fable / Mythos 使用 adaptive，其余（含非 Claude）使用 manual。
    static func thinkingMode(for model: String) -> AnthropicThinkingMode {
        guard let version = version(of: model) else { return .manual }
        if version.family == "fable" || version.family == "mythos" { return .adaptive }
        return isAtLeast(version, 4, 6) ? .adaptive : .manual
    }

    /// 是否支持 `output_config.effort`（adaptive 模型 + Claude Opus 4.5）。
    static func supportsEffort(_ model: String) -> Bool {
        guard let version = version(of: model) else { return false }
        if thinkingMode(for: model) == .adaptive { return true }
        return version.family == "opus" && version.major == 4 && version.minor == 5
    }

    /// 非默认 temperature / top_p / top_k 在这些模型上一律返回 400（Opus 4.7+、5.x、Fable、Mythos）。
    static func rejectsSamplingParameters(_ model: String) -> Bool {
        guard let version = version(of: model) else { return false }
        if version.family == "fable" || version.family == "mythos" { return true }
        return isAtLeast(version, 4, 7)
    }

    /// 自动模式下的 max_tokens（流式主循环）。
    /// 4.6+/5.x 模型同步上限 128K、默认开启思考，取 32K 给思考 + 大文件写入留足空间；
    /// 其余 Claude 4.x / 3.7 取 16K；Claude 3.5 / 未知模型保持此前的 8192，避免第三方端点拒绝。
    static func defaultMaxOutputTokens(for model: String) -> Int {
        guard let version = version(of: model) else { return 8192 }
        if version.family == "fable" || version.family == "mythos" || isAtLeast(version, 4, 6) { return 32_000 }
        if isAtLeast(version, 3, 7) { return 16_000 }
        if version.major == 3 && version.minor == 0 && version.family == "haiku" { return 4096 }
        return 8192
    }

    /// 上下文窗口（platform.claude.com「Context windows」，2026-10）：
    /// Fable / Mythos 全系、Opus / Sonnet 4.6 及之后、Haiku 5 及之后为 1M（默认即 1M，无需 beta 头）；
    /// 其余 Claude（含 Sonnet 4.5、Haiku 4.5）为 200K；无法识别的模型返回 nil。
    static func contextWindow(for model: String) -> Int? {
        guard let version = version(of: model) else { return nil }
        switch version.family {
        case "fable", "mythos":
            return 1_000_000
        case "haiku":
            return isAtLeast(version, 5, 0) ? 1_000_000 : 200_000
        default:
            return isAtLeast(version, 4, 6) ? 1_000_000 : 200_000
        }
    }

    /// manual 模式的思考预算：须 ≥1024 且 < max_tokens；空间不足时返回 nil（不开启思考）。
    static func manualThinkingBudget(level: AIThinkingLevel, maxTokens: Int) -> Int? {
        let desired: Int
        switch level {
        case .modelDefault: return nil
        case .low: desired = 2048
        case .medium: desired = 8192
        case .high: desired = 16_384
        }
        // 至少给可见回复留 1024 token
        let ceiling = maxTokens - 1024
        guard ceiling >= 1024 else { return nil }
        return min(desired, ceiling)
    }

    /// 从 400 错误信息判断应切换到的思考模式；无关错误返回 nil。
    /// - "adaptive thinking is not supported on this model" → manual
    /// - "\"thinking.type.enabled\" is not supported for this model…" → adaptive
    static func thinkingModeFallback(from message: String) -> AnthropicThinkingMode? {
        let lower = message.lowercased()
        guard lower.contains("not supported") else { return nil }
        if lower.contains("adaptive thinking") || lower.contains("thinking.type.adaptive\" is not") {
            return .manual
        }
        if lower.contains("thinking.type.enabled") || lower.contains("budget_tokens") {
            return .adaptive
        }
        return nil
    }
}
