/// 文件说明：AIProviderSettings，AI 服务来源（自有端点 / Apple Private Cloud Compute）的本地配置。
import Foundation

/// AIProviderKind：用户选择的 AI 服务来源。
nonisolated enum AIProviderKind: String, CaseIterable, Sendable {
    /// 用户自有的 OpenAI 兼容 / Anthropic 端点。
    case customEndpoint = "custom"
    /// Apple Foundation Models 运行于 Private Cloud Compute 的服务器模型（iOS 27+）。
    case applePrivateCloudCompute = "applePCC"
}

extension AIProviderKind {
    /// 本地化展示名称（仅供 UI 使用）。
    var displayName: String {
        switch self {
        case .customEndpoint:
            return String(localized: "Custom Endpoint", bundle: LanguageSettings.currentBundle)
        case .applePrivateCloudCompute:
            return String(localized: "Apple Private Cloud Compute", bundle: LanguageSettings.currentBundle)
        }
    }

    /// 对应的 SF Symbol。
    var systemImage: String {
        switch self {
        case .customEndpoint: return "server.rack"
        case .applePrivateCloudCompute: return "apple.intelligence"
        }
    }
}

/// AIProviderSettings：服务来源选择与 PCC 上下文窗口缓存，存于 `UserDefaults`。
nonisolated enum AIProviderSettings {
    static let providerKey = "aiProviderKind"
    static let pccContextSizeKey = "aiPCCContextSize"
    /// 尚未从系统读到 `contextSize` 时使用的 PCC 窗口（Apple 文档：32K）。
    static let defaultPCCContextSize = 32_768
    /// PCC 窗口内为模型回复预留的 token。
    static let pccOutputReserve = 4_096

    /// 读取已保存的服务来源，缺省为自有端点。
    static func load(defaults: UserDefaults = .standard) -> AIProviderKind {
        AIProviderKind(rawValue: defaults.string(forKey: providerKey) ?? "") ?? .customEndpoint
    }

    /// 保存服务来源。
    static func save(_ kind: AIProviderKind, defaults: UserDefaults = .standard) {
        defaults.set(kind.rawValue, forKey: providerKey)
    }

    /// 当前系统是否支持 PCC（iOS 27+）。iOS 26 上 Apple 选项完全隐藏。
    static var isPCCSupportedOS: Bool {
        if #available(iOS 27.0, macOS 27.0, *) { return true }
        return false
    }

    /// 用户保存的选择为 PCC 且系统支持（不考虑当前可用性）；路由据此决定是否先尝试 PCC，
    /// 不可用时由 `RoutingAIService` 回退到自有端点或把原因展示给用户。
    static func isPCCSelected(defaults: UserDefaults = .standard) -> Bool {
        load(defaults: defaults) == .applePrivateCloudCompute && isPCCSupportedOS
    }

    /// 实际生效的服务来源：保存为 PCC 但系统不支持或 PCC 当前不可用时，生效为自有端点。
    /// 保存值本身不被改写，PCC 恢复可用后自动重新生效。
    static func effectiveProvider(
        saved: AIProviderKind,
        isPCCSupportedOS: Bool,
        pccUnavailableReason: PCCFailure?
    ) -> AIProviderKind {
        guard saved == .applePrivateCloudCompute, isPCCSupportedOS, pccUnavailableReason == nil else {
            return .customEndpoint
        }
        return .applePrivateCloudCompute
    }

    /// 读取保存值与系统 PCC 可用性，得到当前生效的服务来源。
    static func loadEffectiveProvider(defaults: UserDefaults = .standard) -> AIProviderKind {
        let saved = load(defaults: defaults)
        guard saved == .applePrivateCloudCompute else { return saved }
        return effectiveProvider(
            saved: saved,
            isPCCSupportedOS: isPCCSupportedOS,
            pccUnavailableReason: PCCAvailabilityProbe.currentUnavailableReason()
        )
    }

    /// 最近一次从系统读到的 PCC 上下文窗口。
    static func cachedPCCContextSize(defaults: UserDefaults = .standard) -> Int {
        let stored = defaults.integer(forKey: pccContextSizeKey)
        return stored > 0 ? stored : defaultPCCContextSize
    }

    /// 缓存系统返回的 PCC 上下文窗口。
    static func storePCCContextSize(_ size: Int, defaults: UserDefaults = .standard) {
        guard size > 0 else { return }
        defaults.set(size, forKey: pccContextSizeKey)
    }

    /// 压缩判定使用的 PCC 上下文预算：窗口减去输出预留，下限 4K。
    static func pccContextBudget(contextSize: Int) -> Int {
        max(contextSize - pccOutputReserve, 4_000)
    }
}
