/// 文件说明：HostKeyConfirmationSheet，首次连接或密钥变化时展示 SHA256 指纹。
import SwiftUI

/// HostKeyConfirmationSheet：
/// 接受才会让握手继续并写入指纹；取消则拒绝，不改已保存的记录。
struct HostKeyConfirmationSheet: View {
    let prompt: HostKeyPrompt
    let onDecision: (HostKeyPromptDecision) -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(prompt.endpoint)
                        .font(.headline)
                    Text(explanation)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    fingerprintBlock
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    Button(trustTitle) { onDecision(.accept) }
                        .buttonStyle(.borderedProminent)
                        .frame(maxWidth: .infinity)
                    Button(String(localized: "Cancel", bundle: LanguageSettings.currentBundle), role: .cancel) {
                        onDecision(.reject)
                    }
                    .frame(maxWidth: .infinity)
                }
                .padding()
                .background(.ultraThinMaterial)
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var title: String {
        switch prompt.admission {
        case .firstUse:
            String(localized: "Verify Host Key", bundle: LanguageSettings.currentBundle)
        case .changed, .trusted:
            String(localized: "Host Key Changed", bundle: LanguageSettings.currentBundle)
        }
    }

    private var trustTitle: String {
        switch prompt.admission {
        case .firstUse:
            String(localized: "Trust This Key", bundle: LanguageSettings.currentBundle)
        case .changed, .trusted:
            String(localized: "Trust New Key", bundle: LanguageSettings.currentBundle)
        }
    }

    private var explanation: String {
        switch prompt.admission {
        case .firstUse:
            String(
                localized: "This is the first connection to this server. Trust it only if the SHA256 fingerprint matches a value you received from a trusted source.",
                bundle: LanguageSettings.currentBundle
            )
        case .changed, .trusted:
            String(
                localized: "The host key changed. This can happen after a server reinstall, or it can mean someone is intercepting the connection. Compare both fingerprints before trusting the new key.",
                bundle: LanguageSettings.currentBundle
            )
        }
    }

    @ViewBuilder
    private var fingerprintBlock: some View {
        switch prompt.admission {
        case .firstUse(let fingerprint):
            fingerprintCard(
                title: String(localized: "SHA256 Fingerprint", bundle: LanguageSettings.currentBundle),
                hex: fingerprint
            )
        case .changed(let stored, let received):
            fingerprintCard(
                title: String(localized: "Stored fingerprint", bundle: LanguageSettings.currentBundle),
                hex: stored
            )
            fingerprintCard(
                title: String(localized: "New fingerprint", bundle: LanguageSettings.currentBundle),
                hex: received
            )
        case .trusted:
            EmptyView()
        }
    }

    private func fingerprintCard(title: String, hex: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(HostKeyFingerprint.openSSH(hex: hex))
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(Color.secondary.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
