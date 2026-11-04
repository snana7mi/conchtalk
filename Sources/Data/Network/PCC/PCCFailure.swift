/// 文件说明：PCCFailure，Apple Private Cloud Compute 失败原因的平台无关表示与回退策略。
import Foundation

/// PCCFailure：PCC 不可用或请求失败的原因（不依赖 FoundationModels，iOS 26 也可编译/测试）。
nonisolated enum PCCFailure: Equatable, Sendable {
    /// 设备不支持 Apple Intelligence。
    case deviceNotEligible
    /// Apple Intelligence 未开启或模型尚未就绪。
    case systemNotReady
    /// 当日额度已用完；`resetDate` 为系统给出的重置时间（可能缺失）。
    case quotaLimitReached(resetDate: Date?)
    /// 网络不可用或请求未能送达。
    case networkFailure
    /// PCC 服务暂时不可用。
    case serviceUnavailable

    /// 是否允许改用用户自有端点重试。上述原因都与请求内容无关，可安全回退。
    var allowsFallback: Bool { true }
}

/// PCCServiceError：面向界面的 PCC 错误。
nonisolated struct PCCServiceError: LocalizedError, Equatable, Sendable {
    let failure: PCCFailure

    var errorDescription: String? {
        let bundle = LanguageSettings.currentBundle
        switch failure {
        case .deviceNotEligible:
            return String(localized: "This device doesn’t support Apple Intelligence, so Private Cloud Compute isn’t available. Choose Custom Endpoint in Settings.", bundle: bundle)
        case .systemNotReady:
            return String(localized: "Private Cloud Compute isn’t ready. Make sure Apple Intelligence is turned on, then try again.", bundle: bundle)
        case .quotaLimitReached(let resetDate):
            guard let resetDate else {
                return String(localized: "You’ve reached today’s Private Cloud Compute limit. Try again later.", bundle: bundle)
            }
            return String(
                format: String(localized: "You’ve reached today’s Private Cloud Compute limit. It resets %@.", bundle: bundle),
                locale: LanguageSettings.currentLocale,
                PCCServiceError.formatResetDate(resetDate)
            )
        case .networkFailure:
            return String(localized: "Couldn’t reach Private Cloud Compute. Check your network connection and try again.", bundle: bundle)
        case .serviceUnavailable:
            return String(localized: "Private Cloud Compute is temporarily unavailable. Try again later.", bundle: bundle)
        }
    }

    /// 重置时间的本地化展示（日期 + 时间，跟随应用语言）。
    static func formatResetDate(_ date: Date) -> String {
        date.formatted(
            Date.FormatStyle(date: .abbreviated, time: .shortened)
                .locale(LanguageSettings.currentLocale)
        )
    }
}

/// PCCFallbackPolicy：决定 PCC 失败后是否改走用户自有端点。
nonisolated enum PCCFallbackPolicy {
    /// - Parameters:
    ///   - error: PCC 流产出的错误。
    ///   - hasEmittedOutput: 本轮是否已向上层输出过正文 / 推理 / 工具调用（已输出则不再切换，避免重复内容）。
    ///   - customEndpointConfigured: 用户是否配置了完整的自有端点。
    static func shouldFallBack(after error: Error, hasEmittedOutput: Bool, customEndpointConfigured: Bool) -> Bool {
        guard !hasEmittedOutput, customEndpointConfigured,
              let pccError = error as? PCCServiceError else { return false }
        return pccError.failure.allowsFallback
    }
}
