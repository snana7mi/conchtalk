/// 文件说明：CloudSyncSettingsView，云同步设置与状态展示页面。
import SwiftUI

/// CloudSyncSettingsView：展示云同步开关、状态和操作。
struct CloudSyncSettingsView: View {
    let authService: AuthService
    let syncService: SyncService
    let subscriptionService: SubscriptionService
    @State private var showPaywall = false
    @State private var isEnabled = SyncState.isEnabled
    @State private var lastResult: SyncService.SyncResult?
    @State private var showDisableConfirmation = false
    /// 防止程序化重置 toggle 时触发 onChange 副作用（sync / disable 流程）。
    @State private var suppressOnChange = false
    /// 同步结果一闪而过的提示文字。
    @State private var syncToastMessage: String?
    @State private var syncToastIsError = false

    private var isPaid: Bool {
        authService.currentUser?.tier == "paid"
    }

    var body: some View {
        Form {
            Section {
                Toggle(String(localized: "Enable Cloud Sync", bundle: LanguageSettings.currentBundle), isOn: $isEnabled)
                    .disabled(!isPaid || !authService.isLoggedIn)
                    .onChange(of: isEnabled) { _, newValue in
                        guard !suppressOnChange else { suppressOnChange = false; return }
                        if newValue {
                            // 用户主动开启同步
                            SyncState.isEnabled = true
                            SyncState.disabledByUserID = nil
                            Task {
                                let before = lastResult?.timestamp
                                await syncService.sync()
                                lastResult = await syncService.lastResult
                                if lastResult?.timestamp != before {
                                    showSyncToast(for: lastResult)
                                }
                            }
                        } else {
                            // 关闭前弹确认
                            showDisableConfirmation = true
                        }
                    }

                if !authService.isLoggedIn {
                    Text(String(localized: "Sign in to use cloud sync", bundle: LanguageSettings.currentBundle))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if !isPaid {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(String(localized: "Cloud sync requires a paid subscription", bundle: LanguageSettings.currentBundle))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button(String(localized: "Upgrade to Pro", bundle: LanguageSettings.currentBundle)) {
                            showPaywall = true
                        }
                        .font(.caption)
                    }
                }
            } header: {
                Text(String(localized: "Cloud Sync", bundle: LanguageSettings.currentBundle))
            } footer: {
                Text(String(localized: "Data is encrypted end-to-end. Only you can decrypt it.", bundle: LanguageSettings.currentBundle))
            }

            if isEnabled && isPaid {
                Section {
                    Button(String(localized: "Force Full Sync", bundle: LanguageSettings.currentBundle)) {
                        Task {
                            let before = lastResult?.timestamp
                            await syncService.forceFullSync()
                            lastResult = await syncService.lastResult
                            if lastResult?.timestamp != before {
                                showSyncToast(for: lastResult)
                            }
                        }
                    }
                } footer: {
                    Text(String(localized: "Re-upload all local data and re-download all cloud data.", bundle: LanguageSettings.currentBundle))
                }
            }

        }
        .navigationTitle(String(localized: "Cloud Sync", bundle: LanguageSettings.currentBundle))
        .task {
            lastResult = await syncService.lastResult
        }
        // 关闭同步确认
        .alert(String(localized: "Disable Cloud Sync?", bundle: LanguageSettings.currentBundle), isPresented: $showDisableConfirmation) {
            Button(String(localized: "Disable and Delete", bundle: LanguageSettings.currentBundle), role: .destructive) {
                Task {
                    let success = await syncService.disableAndDeleteCloudData()
                    if !success {
                        // 删除失败，恢复 toggle 为开启（抑制 onChange 避免触发 sync）
                        suppressOnChange = true
                        isEnabled = true
                    }
                }
            }
            Button(String(localized: "Cancel", bundle: LanguageSettings.currentBundle), role: .cancel) {
                // 恢复 toggle 状态（抑制 onChange 避免触发 sync）
                suppressOnChange = true
                isEnabled = true
            }
        } message: {
            Text(String(localized: "All cloud sync data will be permanently deleted. Local data on this device will not be affected.", bundle: LanguageSettings.currentBundle))
        }
        .overlay(alignment: .top) {
            if let message = syncToastMessage {
                Text(message)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(syncToastIsError ? .red : .green)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .padding(.top, 8)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: syncToastMessage)
        .sheet(isPresented: $showPaywall) {
            PaywallView(viewModel: PaywallViewModel(subscriptionService: subscriptionService))
        }
    }

    /// 根据同步结果显示一闪而过的 toast 提示。
    private func showSyncToast(for result: SyncService.SyncResult?) {
        guard let result else { return }
        if result.success {
            if result.prunedCount > 0 {
                syncToastMessage = String(localized: "Cloud storage full. \(result.prunedCount) old messages auto-cleaned.", bundle: LanguageSettings.currentBundle)
                syncToastIsError = true
            } else {
                syncToastMessage = String(localized: "Sync successful", bundle: LanguageSettings.currentBundle)
                syncToastIsError = false
            }
        } else {
            syncToastMessage = result.error ?? String(localized: "Sync failed", bundle: LanguageSettings.currentBundle)
            syncToastIsError = true
        }
        Task {
            try? await Task.sleep(for: .seconds(2))
            syncToastMessage = nil
        }
    }
}
