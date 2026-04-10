/// 文件说明：ConnectionBannerView，承载聊天页连接状态横幅 UI。
import SwiftUI

struct ConnectionBannerView: View {
    let isReconnecting: Bool
    let isConnected: Bool
    let onReconnect: () -> Void

    @ViewBuilder
    var body: some View {
        if isReconnecting {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.mini)
                Text(String(localized: "Reconnecting…", bundle: LanguageSettings.currentBundle))
                    .font(.caption)
                Spacer()
            }
            .padding(.horizontal, Theme.screenPadding)
            .padding(.vertical, 6)
            .background(Color.orange.opacity(0.12))
            .foregroundStyle(.orange)
            .transition(.move(edge: .top).combined(with: .opacity))
        } else if !isConnected {
            HStack(spacing: 6) {
                Image(systemName: "wifi.slash")
                    .font(.caption)
                Text(String(localized: "Connection lost", bundle: LanguageSettings.currentBundle))
                    .font(.caption)
                Spacer()
                Button(action: onReconnect) {
                    Text(String(localized: "Reconnect", bundle: LanguageSettings.currentBundle))
                        .font(.caption)
                        .fontWeight(.medium)
                }
            }
            .padding(.horizontal, Theme.screenPadding)
            .padding(.vertical, 6)
            .background(Color.red.opacity(0.12))
            .foregroundStyle(.red)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}
