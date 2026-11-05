/// 文件说明：ApplePCCStatusView，在设置页展示 Apple Private Cloud Compute 的可用性、每日额度与上下文窗口。
import SwiftUI
import FoundationModels

/// ApplePCCStatusView：
/// 只使用系统控件（`LabeledContent`、`Label`、`Button`）。`PrivateCloudComputeLanguageModel` 可观察，
/// 可用性与额度变化会自动刷新。
@available(iOS 27.0, macOS 27.0, *)
struct ApplePCCStatusView: View {
    @State private var model = PrivateCloudComputeLanguageModel()
    @State private var contextSize: Int?

    var body: some View {
        LabeledContent(String(localized: "Status", bundle: LanguageSettings.currentBundle)) {
            availabilityLabel
        }

        if model.isAvailable {
            LabeledContent(String(localized: "Daily Limit", bundle: LanguageSettings.currentBundle)) {
                quotaLabel
            }

            if let suggestion = model.quotaUsage.limitIncreaseSuggestion {
                Button {
                    suggestion.show()
                } label: {
                    Label(
                        String(localized: "Increase Limit with iCloud+", bundle: LanguageSettings.currentBundle),
                        systemImage: "icloud"
                    )
                }
            }

            if let contextSize {
                LabeledContent(
                    String(localized: "Context Window", bundle: LanguageSettings.currentBundle),
                    value: String(
                        format: String(localized: "%@ tokens", bundle: LanguageSettings.currentBundle),
                        DirectContextUsage.compact(contextSize)
                    )
                )
            }
        }
    }

    @ViewBuilder
    private var availabilityLabel: some View {
        switch model.availability {
        case .available:
            Label(String(localized: "Ready", bundle: LanguageSettings.currentBundle), systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .task { await loadContextSize() }
        case .unavailable(.deviceNotEligible):
            Label(String(localized: "Device Not Supported", bundle: LanguageSettings.currentBundle), systemImage: "xmark.circle")
                .foregroundStyle(.secondary)
        case .unavailable:
            Label(String(localized: "Turn On Apple Intelligence", bundle: LanguageSettings.currentBundle), systemImage: "exclamationmark.circle")
                .foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private var quotaLabel: some View {
        let usage = model.quotaUsage
        switch usage.status {
        case .limitReached:
            if let resetDate = usage.resetDate {
                Label(
                    String(
                        format: String(localized: "Reached · resets %@", bundle: LanguageSettings.currentBundle),
                        PCCServiceError.formatResetDate(resetDate)
                    ),
                    systemImage: "gauge.with.dots.needle.100percent"
                )
                .foregroundStyle(.red)
            } else {
                Label(String(localized: "Reached", bundle: LanguageSettings.currentBundle), systemImage: "gauge.with.dots.needle.100percent")
                    .foregroundStyle(.red)
            }
        case .belowLimit(let below) where below.isApproachingLimit:
            Label(String(localized: "Approaching Limit", bundle: LanguageSettings.currentBundle), systemImage: "gauge.with.dots.needle.67percent")
                .foregroundStyle(.orange)
        case .belowLimit:
            Label(String(localized: "Within Limit", bundle: LanguageSettings.currentBundle), systemImage: "gauge.with.dots.needle.33percent")
                .foregroundStyle(.secondary)
        @unknown default:
            EmptyView()
        }
    }

    private func loadContextSize() async {
        guard let size = try? await model.contextSize else { return }
        contextSize = size
        AIProviderSettings.storePCCContextSize(size)
    }
}
