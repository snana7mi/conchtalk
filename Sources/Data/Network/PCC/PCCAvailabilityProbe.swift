/// 文件说明：PCCAvailabilityProbe，读取 Apple Private Cloud Compute 当前可用性（iOS 26 上恒为不支持）。
import Foundation
import Observation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// PCCAvailabilityProbe：
/// - `currentUnavailableReason()`：一次性读取（路由 / 预算使用）。
/// - 实例：供 SwiftUI 使用；内部持有可观察的 `PrivateCloudComputeLanguageModel`，
///   在 `body` 中读取 `unavailableReason` 时会随系统可用性变化自动刷新。
@MainActor
@Observable
final class PCCAvailabilityProbe {
    /// iOS 27+ 时为 `PrivateCloudComputeLanguageModel`；类型擦除以便在 iOS 26 部署目标下存储。
    @ObservationIgnored private let model: AnyObject?

    init() {
        if #available(iOS 27.0, macOS 27.0, *) {
            model = PrivateCloudComputeLanguageModel()
        } else {
            model = nil
        }
    }

    /// 当前不可用原因；可用时为 nil。系统不支持（iOS 26）时为 nil，由 `isSupportedOS` 区分。
    var unavailableReason: PCCFailure? {
        if #available(iOS 27.0, macOS 27.0, *), let model = model as? PrivateCloudComputeLanguageModel {
            return Self.reason(of: model)
        }
        return nil
    }

    var isSupportedOS: Bool { model != nil }

    nonisolated static func currentUnavailableReason() -> PCCFailure? {
        if #available(iOS 27.0, macOS 27.0, *) {
            return reason(of: PrivateCloudComputeLanguageModel())
        }
        return nil
    }

    @available(iOS 27.0, macOS 27.0, *)
    nonisolated private static func reason(of model: PrivateCloudComputeLanguageModel) -> PCCFailure? {
        switch model.availability {
        case .available: return nil
        case .unavailable(let reason): return PCCAIService.failure(for: reason)
        }
    }
}

extension PCCFailure {
    /// 设置页使用的简短原因。
    var shortReason: String {
        let bundle = LanguageSettings.currentBundle
        switch self {
        case .deviceNotEligible:
            return String(localized: "Device Not Supported", bundle: bundle)
        case .systemNotReady:
            return String(localized: "Turn On Apple Intelligence", bundle: bundle)
        case .quotaLimitReached:
            return String(localized: "Reached", bundle: bundle)
        case .networkFailure, .serviceUnavailable:
            return String(localized: "Temporarily Unavailable", bundle: bundle)
        }
    }
}
