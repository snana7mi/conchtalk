/// 文件说明：SettingsView，负责应用设置页面与配置项展示。
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// SettingsView：负责界面渲染与用户交互响应。
struct SettingsView: View {
    @Binding var selectedLanguage: AppLanguage
    @State private var apiKey: String
    @State private var endpointURL: String
    @State private var modelName: String
    @State private var maxContextTokensK: Int
    @State private var useLocalConfig: Bool
    @State private var apiFormat: APIFormat
    @State private var permissionLevel: PermissionLevel
    @State private var showPermissiveWarning = false
    @State private var previousPermissionLevel: PermissionLevel = .standard
    @State private var showSaved = false
    @State private var toolbarAvatarImage: Image?

    // Cloud Sync 状态
    @State private var syncEnabled = SyncState.isEnabled
    @State private var syncLastResult: SyncService.SyncResult?
    @State private var showDisableConfirmation = false
    @State private var suppressSyncOnChange = false
    @State private var showPaywall = false
    /// 同步结果一闪而过的提示文字。
    @State private var syncToastMessage: String?
    @State private var syncToastIsError = false

    /// 初始化时保存的快照，用于判断是否有未保存的改动。
    @State private var savedSettings: AISettings

    var authService: AuthService
    var sshKeyManagementViewModel: SSHKeyManagementViewModel
    var syncService: SyncService
    var subscriptionService: SubscriptionService
    @Binding private var reportUnsavedChanges: Bool
    @Binding private var triggerSave: Bool

    private var hasUnsavedChanges: Bool {
        apiKey != savedSettings.apiKey
            || endpointURL != savedSettings.endpointURL
            || modelName != savedSettings.modelName
            || maxContextTokensK != savedSettings.maxContextTokensK
            || useLocalConfig != savedSettings.useLocalConfig
            || apiFormat != savedSettings.apiFormat
            || permissionLevel != savedSettings.permissionLevel
    }

    private func saveSettings() {
        let settings = AISettings(
            apiKey: apiKey,
            endpointURL: endpointURL,
            modelName: modelName,
            maxContextTokensK: max(maxContextTokensK, 1),
            useLocalConfig: useLocalConfig,
            apiFormat: apiFormat,
            permissionLevel: permissionLevel
        )
        settings.save()
        savedSettings = settings
        reportUnsavedChanges = false
    }

    /// 初始化设置页面并加载当前配置。
    init(selectedLanguage: Binding<AppLanguage>, authService: AuthService,
         sshKeyManagementViewModel: SSHKeyManagementViewModel,
         syncService: SyncService,
         subscriptionService: SubscriptionService,
         reportUnsavedChanges: Binding<Bool> = .constant(false),
         triggerSave: Binding<Bool> = .constant(false)) {
        _selectedLanguage = selectedLanguage
        self.authService = authService
        self.sshKeyManagementViewModel = sshKeyManagementViewModel
        self.syncService = syncService
        self.subscriptionService = subscriptionService
        _reportUnsavedChanges = reportUnsavedChanges
        _triggerSave = triggerSave
        let settings = AISettings.load()
        _savedSettings = State(initialValue: settings)
        _apiKey = State(initialValue: settings.apiKey)
        _endpointURL = State(initialValue: settings.endpointURL)
        _modelName = State(initialValue: settings.modelName)
        _maxContextTokensK = State(initialValue: settings.maxContextTokensK)
        _useLocalConfig = State(initialValue: settings.useLocalConfig)
        _apiFormat = State(initialValue: settings.apiFormat)
        _permissionLevel = State(initialValue: settings.permissionLevel)
    }

    var body: some View {
        Form {
            Section {
                HStack {
                    Text(String(localized: "Settings", bundle: LanguageSettings.currentBundle))
                        .font(.largeTitle.bold())
                    Spacer()
                    toolbarAvatarView
                        .onTapGesture { navigateToProfile = true }
                        .accessibilityAddTraits(.isButton)
                        .accessibilityLabel("Profile")
                }
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))

            Section(String(localized: "Language", bundle: LanguageSettings.currentBundle)) {
                Picker(String(localized: "Language", bundle: LanguageSettings.currentBundle),
                       selection: Binding(
                           get: { selectedLanguage },
                           set: { newValue in
                               // 先清缓存再更新状态，确保 SwiftUI 重绘时读到新 bundle
                               LanguageSettings(language: newValue).save()
                               selectedLanguage = newValue
                           }
                       )) {
                    ForEach(AppLanguage.allCases, id: \.self) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                }
            }

            permissionLevelSection

            Section(String(localized: "SSH Keys", bundle: LanguageSettings.currentBundle)) {
                NavigationLink {
                    SSHKeyManagementView(viewModel: sshKeyManagementViewModel)
                } label: {
                    Label(String(localized: "Manage SSH Keys", bundle: LanguageSettings.currentBundle), systemImage: "key")
                }
            }

            cloudSyncSection

            aiServiceSection

            Section {
                Button(action: {
                    saveSettings()
                    showSaved = true
                }) {
                    HStack {
                        Text(String(localized: "Save Settings", bundle: LanguageSettings.currentBundle))
                            .fontWeight(hasUnsavedChanges ? .semibold : .regular)
                        Spacer()
                        if hasUnsavedChanges {
                            Text(String(localized: "Unsaved changes", bundle: LanguageSettings.currentBundle))
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }
                .foregroundStyle(hasUnsavedChanges ? .orange : .accentColor)

                if hasUnsavedChanges {
                    Button(String(localized: "Discard Changes", bundle: LanguageSettings.currentBundle), role: .destructive) {
                        let settings = savedSettings
                        apiKey = settings.apiKey
                        endpointURL = settings.endpointURL
                        modelName = settings.modelName
                        maxContextTokensK = settings.maxContextTokensK
                        useLocalConfig = settings.useLocalConfig
                        apiFormat = settings.apiFormat
                        permissionLevel = settings.permissionLevel
                        reportUnsavedChanges = false
                    }
                }
            }

            Section(String(localized: "About", bundle: LanguageSettings.currentBundle)) {
                LabeledContent(String(localized: "Version", bundle: LanguageSettings.currentBundle), value: "1.0.0")
                LabeledContent(String(localized: "App", bundle: LanguageSettings.currentBundle), value: "ConchTalk")
            }
        }
        .id(selectedLanguage)
        .scrollDismissesKeyboard(.interactively)
        #if os(iOS)
        .background(KeyboardDismissView())
        #endif
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $navigateToProfile) {
            ProfileView(authService: authService, subscriptionService: subscriptionService)
        }
        .task(id: authService.currentUser?.avatarURL ?? authService.currentUser?.id) {
            await loadToolbarAvatar()
        }
        .onChange(of: authService.isLoggedIn) {
            if !authService.isLoggedIn {
                toolbarAvatarImage = nil
            }
        }
        .alert(String(localized: "Settings Saved", bundle: LanguageSettings.currentBundle), isPresented: $showSaved) {
            Button(String(localized: "OK", bundle: LanguageSettings.currentBundle)) {}
        }
        // 关闭同步确认
        .alert(String(localized: "Disable Cloud Sync?", bundle: LanguageSettings.currentBundle), isPresented: $showDisableConfirmation) {
            Button(String(localized: "Disable and Delete", bundle: LanguageSettings.currentBundle), role: .destructive) {
                Task {
                    let success = await syncService.disableAndDeleteCloudData()
                    if !success {
                        suppressSyncOnChange = true
                        syncEnabled = true
                    }
                }
            }
            Button(String(localized: "Cancel", bundle: LanguageSettings.currentBundle), role: .cancel) {
                suppressSyncOnChange = true
                syncEnabled = true
            }
        } message: {
            Text(String(localized: "All cloud sync data will be permanently deleted. Local data on this device will not be affected.", bundle: LanguageSettings.currentBundle))
        }
        .sheet(isPresented: $showPaywall) {
            PaywallView(viewModel: PaywallViewModel(subscriptionService: subscriptionService))
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
        .task {
            syncLastResult = await syncService.lastResult
        }
        .onChange(of: apiKey) { reportUnsavedChanges = hasUnsavedChanges }
        .onChange(of: endpointURL) { reportUnsavedChanges = hasUnsavedChanges }
        .onChange(of: modelName) { reportUnsavedChanges = hasUnsavedChanges }
        .onChange(of: maxContextTokensK) { reportUnsavedChanges = hasUnsavedChanges }
        .onChange(of: useLocalConfig) { reportUnsavedChanges = hasUnsavedChanges }
        .onChange(of: apiFormat) { reportUnsavedChanges = hasUnsavedChanges }
        .onChange(of: permissionLevel) { reportUnsavedChanges = hasUnsavedChanges }
        .onChange(of: triggerSave) {
            if triggerSave {
                saveSettings()
                triggerSave = false
            }
        }
    }

    // MARK: - Cloud Sync Section

    private var isPaid: Bool {
        authService.currentUser?.tier == "paid"
    }

    @ViewBuilder
    private var cloudSyncSection: some View {
        Section {
            Toggle(String(localized: "Enable Cloud Sync", bundle: LanguageSettings.currentBundle), isOn: $syncEnabled)
                .disabled(!isPaid || !authService.isLoggedIn)
                .onChange(of: syncEnabled) { _, newValue in
                    guard !suppressSyncOnChange else { suppressSyncOnChange = false; return }
                    if newValue {
                        SyncState.isEnabled = true
                        SyncState.disabledByUserID = nil
                        Task {
                            let before = syncLastResult?.timestamp
                            await syncService.sync()
                            syncLastResult = await syncService.lastResult
                            if syncLastResult?.timestamp != before {
                                showSyncToast(for: syncLastResult)
                            }
                        }
                    } else {
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
            if syncEnabled && isPaid {
                Button(String(localized: "Force Full Sync", bundle: LanguageSettings.currentBundle)) {
                    Task {
                        let before = syncLastResult?.timestamp
                        await syncService.forceFullSync()
                        syncLastResult = await syncService.lastResult
                        if syncLastResult?.timestamp != before {
                            showSyncToast(for: syncLastResult)
                        }
                    }
                }
            }
        } header: {
            Text(String(localized: "Cloud Sync", bundle: LanguageSettings.currentBundle))
        } footer: {
            Text(String(localized: "Data is encrypted end-to-end. Only you can decrypt it.", bundle: LanguageSettings.currentBundle))
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

    // MARK: - AI Service Section

    private var aiServiceSection: some View {
        Section {
            Toggle(String(localized: "Use Custom API", bundle: LanguageSettings.currentBundle), isOn: $useLocalConfig)

            if useLocalConfig {
                Picker(String(localized: "API Format", bundle: LanguageSettings.currentBundle), selection: $apiFormat) {
                    ForEach(APIFormat.allCases, id: \.self) { format in
                        Text(format.displayName).tag(format)
                    }
                }

                SecureField(String(localized: "API Key", bundle: LanguageSettings.currentBundle), text: $apiKey)

                TextField(String(localized: "Endpoint URL", bundle: LanguageSettings.currentBundle), text: $endpointURL)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
            }

            TextField(String(localized: "Model", bundle: LanguageSettings.currentBundle), text: $modelName)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            HStack {
                Text(String(localized: "Max Context", bundle: LanguageSettings.currentBundle))
                Spacer()
                TextField("128", value: $maxContextTokensK, format: .number)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
                    .keyboardType(.numberPad)
                Text(String(localized: "K tokens", bundle: LanguageSettings.currentBundle))
                    .foregroundStyle(.secondary)
            }

            if !useLocalConfig {
                Text(String(localized: "Using ConchTalk cloud AI service", bundle: LanguageSettings.currentBundle))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text(String(localized: "AI Service", bundle: LanguageSettings.currentBundle))
        } footer: {
            if useLocalConfig {
                Text(String(localized: "Enter the API base URL (e.g. https://api.openai.com/v1). The path will be appended automatically.", bundle: LanguageSettings.currentBundle))
            }
        }
    }

    // MARK: - Permission Level Section

    private var permissionLevelSection: some View {
        Section {
            Picker(String(localized: "Permission Level", bundle: LanguageSettings.currentBundle), selection: $permissionLevel) {
                ForEach(PermissionLevel.allCases, id: \.self) { level in
                    Label {
                        Text(verbatim: level.displayName)
                    } icon: {
                        Image(systemName: level.iconName)
                    }
                    .tag(level)
                }
            }

            Text(verbatim: permissionLevel.descriptionText)
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text(String(localized: "Permission Level", bundle: LanguageSettings.currentBundle))
        } footer: {
            Text(String(localized: "Default permission level for all servers. Individual servers can override this.", bundle: LanguageSettings.currentBundle))
        }
        .onChange(of: permissionLevel) { oldValue, newValue in
            if newValue == .permissive {
                previousPermissionLevel = oldValue
                showPermissiveWarning = true
            }
        }
        .alert(
            String(localized: "Risk Warning", bundle: LanguageSettings.currentBundle),
            isPresented: $showPermissiveWarning
        ) {
            Button(String(localized: "I Understand the Risks", bundle: LanguageSettings.currentBundle)) { }
            Button(String(localized: "Cancel", bundle: LanguageSettings.currentBundle), role: .cancel) {
                permissionLevel = previousPermissionLevel
            }
        } message: {
            Text(String(localized: "Permissive mode auto-executes write commands and allows previously-forbidden destructive commands with confirmation. Only use on trusted or test servers.", bundle: LanguageSettings.currentBundle))
        }
    }

    // MARK: - Toolbar Avatar

    @State private var navigateToProfile = false

    private var toolbarAvatarNavigationLink: some View {
        Button {
            navigateToProfile = true
        } label: {
            toolbarAvatarView
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Profile")
    }

    @ViewBuilder
    private var toolbarAvatarView: some View {
        if authService.isLoggedIn {
            Group {
                if let toolbarAvatarImage {
                    toolbarAvatarImage
                        .resizable()
                        .scaledToFill()
                } else {
                    ZStack {
                        Circle()
                            .fill(Color.secondary.opacity(0.16))
                        Text(ProfileView.avatarInitial(from: authService.currentUser?.displayName))
                            .font(.caption2.bold())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: 45, height: 45)
            .clipShape(Circle())
            .rainbowAvatarBorder(isActive: isPaid, size: 45, lineWidth: 2, glowRadius: 4)
            .contentShape(Circle())
        } else {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
        }
    }

    private func loadToolbarAvatar() async {
        guard authService.isLoggedIn else { return }
        if let data = await authService.loadAvatarDataIfNeeded(),
           let img = ProfileView.makeSwiftUIImage(from: data) {
            toolbarAvatarImage = img
        }
    }
}

#if os(iOS)
/// 通过 UIKit 手势识别器收起键盘，cancelsTouchesInView = false 确保不拦截按钮点击。
private struct KeyboardDismissView: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.dismissKeyboard))
        tap.cancelsTouchesInView = false
        view.addGestureRecognizer(tap)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator {
        @objc func dismissKeyboard() {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
    }
}
#endif
