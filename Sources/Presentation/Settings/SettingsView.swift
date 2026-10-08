/// 文件说明：SettingsView，负责自有 AI 路线与本地应用设置。
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// SettingsView：
/// 展示用户自有 AI API、权限、语言与 SSH 密钥设置；不依赖平台账号或托管网关。
struct SettingsView: View {
    @Binding var selectedLanguage: AppLanguage
    @State private var apiKey: String
    @State private var endpointURL: String
    @State private var modelName: String
    @State private var maxContextTokensK: Int
    /// 最大输出 token（0 = 自动），仅 Anthropic 格式生效。
    @State private var maxOutputTokens: Int
    @State private var thinkingLevel: AIThinkingLevel
    @State private var apiFormat: APIFormat
    @State private var permissionLevel: PermissionLevel
    @State private var webSearchEnabled: Bool
    @State private var webSearchProvider: WebSearchProvider
    @State private var webSearchAPIKeys: [WebSearchProvider: String]
    @State private var showPermissiveWarning = false
    @State private var previousPermissionLevel: PermissionLevel = .standard
    @State private var showSaved = false
    @State private var showWebSearchKeyRequired = false
    @State private var showWebSearchSaveError = false

    /// 初始化时保存的快照，用于判断是否有未保存的改动。
    @State private var savedSettings: AISettings
    @State private var savedWebSearchSettings: WebSearchSettings

    var sshKeyManagementViewModel: SSHKeyManagementViewModel
    @Binding private var reportUnsavedChanges: Bool
    @Binding private var triggerSave: Bool

    private var hasUnsavedChanges: Bool {
        apiKey != savedSettings.apiKey
            || endpointURL != savedSettings.endpointURL
            || modelName != savedSettings.modelName
            || maxContextTokensK != savedSettings.maxContextTokensK
            || maxOutputTokens != savedSettings.maxOutputTokens
            || thinkingLevel != savedSettings.thinkingLevel
            || apiFormat != savedSettings.apiFormat
            || permissionLevel != savedSettings.permissionLevel
            || webSearchEnabled != savedWebSearchSettings.isEnabled
            || webSearchProvider != savedWebSearchSettings.provider
            || webSearchAPIKeys != savedWebSearchSettings.apiKeys
    }

    /// 初始化设置页面并加载当前配置。
    init(
        selectedLanguage: Binding<AppLanguage>,
        sshKeyManagementViewModel: SSHKeyManagementViewModel,
        reportUnsavedChanges: Binding<Bool> = .constant(false),
        triggerSave: Binding<Bool> = .constant(false)
    ) {
        _selectedLanguage = selectedLanguage
        self.sshKeyManagementViewModel = sshKeyManagementViewModel
        _reportUnsavedChanges = reportUnsavedChanges
        _triggerSave = triggerSave

        let settings = AISettings.load()
        let webSearchSettings = WebSearchSettings.load()
        _savedSettings = State(initialValue: settings)
        _savedWebSearchSettings = State(initialValue: webSearchSettings)
        _apiKey = State(initialValue: settings.apiKey)
        _endpointURL = State(initialValue: settings.endpointURL)
        _modelName = State(initialValue: settings.modelName)
        _maxContextTokensK = State(initialValue: settings.maxContextTokensK)
        _maxOutputTokens = State(initialValue: settings.maxOutputTokens)
        _thinkingLevel = State(initialValue: settings.thinkingLevel)
        _apiFormat = State(initialValue: settings.apiFormat)
        _permissionLevel = State(initialValue: settings.permissionLevel)
        _webSearchEnabled = State(initialValue: webSearchSettings.isEnabled)
        _webSearchProvider = State(initialValue: webSearchSettings.provider)
        _webSearchAPIKeys = State(initialValue: webSearchSettings.apiKeys)
    }

    var body: some View {
        Form {
            Section {
                Text(String(localized: "Settings", bundle: LanguageSettings.currentBundle))
                    .font(.largeTitle.bold())
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))

            languageSection
            aiServiceSection
            webSearchSection
            permissionLevelSection

            Section(String(localized: "SSH Keys", bundle: LanguageSettings.currentBundle)) {
                NavigationLink {
                    SSHKeyManagementView(viewModel: sshKeyManagementViewModel)
                } label: {
                    Label(
                        String(localized: "Manage SSH Keys", bundle: LanguageSettings.currentBundle),
                        systemImage: "key"
                    )
                }
            }

            saveSection

            Section(String(localized: "About", bundle: LanguageSettings.currentBundle)) {
                LabeledContent(
                    String(localized: "Version", bundle: LanguageSettings.currentBundle),
                    value: "1.0.0"
                )
                LabeledContent(
                    String(localized: "App", bundle: LanguageSettings.currentBundle),
                    value: "ConchTalk"
                )
            }
        }
        .id(selectedLanguage)
        .scrollDismissesKeyboard(.interactively)
        #if os(iOS)
        .background(KeyboardDismissView())
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .navigationTitle("")
        .alert(
            String(localized: "Settings Saved", bundle: LanguageSettings.currentBundle),
            isPresented: $showSaved
        ) {
            Button(String(localized: "OK", bundle: LanguageSettings.currentBundle)) {}
        }
        .alert(
            String(localized: "Search API Key Required", bundle: LanguageSettings.currentBundle),
            isPresented: $showWebSearchKeyRequired
        ) {
            Button(String(localized: "OK", bundle: LanguageSettings.currentBundle)) {}
        } message: {
            Text(
                String(
                    localized: "Enter an API key for the selected search provider before enabling web search.",
                    bundle: LanguageSettings.currentBundle
                )
            )
        }
        .alert(
            String(localized: "Unable to Save Web Search Settings", bundle: LanguageSettings.currentBundle),
            isPresented: $showWebSearchSaveError
        ) {
            Button(String(localized: "OK", bundle: LanguageSettings.currentBundle)) {}
        } message: {
            Text(
                String(
                    localized: "Check that Keychain access is available and try again.",
                    bundle: LanguageSettings.currentBundle
                )
            )
        }
        .onChange(of: apiKey) { reportUnsavedChanges = hasUnsavedChanges }
        .onChange(of: endpointURL) { reportUnsavedChanges = hasUnsavedChanges }
        .onChange(of: modelName) { reportUnsavedChanges = hasUnsavedChanges }
        .onChange(of: maxContextTokensK) { reportUnsavedChanges = hasUnsavedChanges }
        .onChange(of: maxOutputTokens) { reportUnsavedChanges = hasUnsavedChanges }
        .onChange(of: thinkingLevel) { reportUnsavedChanges = hasUnsavedChanges }
        .onChange(of: apiFormat) { reportUnsavedChanges = hasUnsavedChanges }
        .onChange(of: permissionLevel) { reportUnsavedChanges = hasUnsavedChanges }
        .onChange(of: webSearchEnabled) { reportUnsavedChanges = hasUnsavedChanges }
        .onChange(of: webSearchProvider) { reportUnsavedChanges = hasUnsavedChanges }
        .onChange(of: webSearchAPIKeys) { reportUnsavedChanges = hasUnsavedChanges }
        .onChange(of: triggerSave) {
            if triggerSave {
                _ = saveSettings()
                triggerSave = false
            }
        }
    }

    /// 联网搜索使用用户选择的服务和自有 Key，保存后动态加入/移出工具表。
    private var webSearchSection: some View {
        Section {
            Toggle(
                String(localized: "Enable Web Search", bundle: LanguageSettings.currentBundle),
                isOn: $webSearchEnabled
            )

            if webSearchEnabled {
                Picker(
                    String(localized: "Search Provider", bundle: LanguageSettings.currentBundle),
                    selection: $webSearchProvider
                ) {
                    ForEach(WebSearchProvider.allCases, id: \.self) { provider in
                        Text(verbatim: provider.displayName).tag(provider)
                    }
                }

                SecureField(
                    String(localized: "API Key", bundle: LanguageSettings.currentBundle),
                    text: Binding(
                        get: { webSearchAPIKeys[webSearchProvider] ?? "" },
                        set: { webSearchAPIKeys[webSearchProvider] = $0 }
                    )
                )
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .autocorrectionDisabled()

            }
        } header: {
            Text(String(localized: "Web Search", bundle: LanguageSettings.currentBundle))
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text(
                    String(
                        localized: "Search requests go directly to the selected provider using your own API key. ConchTalk does not proxy them.",
                        bundle: LanguageSettings.currentBundle
                    )
                )
                Text(
                    String(
                        localized: "Your search API keys are stored in the iOS Keychain.",
                        bundle: LanguageSettings.currentBundle
                    )
                )
            }
        }
    }

    private var languageSection: some View {
        Section(String(localized: "Language", bundle: LanguageSettings.currentBundle)) {
            Picker(
                String(localized: "Language", bundle: LanguageSettings.currentBundle),
                selection: Binding(
                    get: { selectedLanguage },
                    set: { newValue in
                        LanguageSettings(language: newValue).save()
                        selectedLanguage = newValue
                    }
                )
            ) {
                ForEach(AppLanguage.allCases, id: \.self) { language in
                    Text(language.displayName).tag(language)
                }
            }
        }
    }

    /// 自有 AI 路线是普通模式的唯一来源，不再提供托管服务开关。
    private var aiServiceSection: some View {
        Section {
            Picker(
                String(localized: "API Format", bundle: LanguageSettings.currentBundle),
                selection: $apiFormat
            ) {
                ForEach(APIFormat.allCases, id: \.self) { format in
                    Text(format.displayName).tag(format)
                }
            }

            SecureField(
                String(localized: "API Key", bundle: LanguageSettings.currentBundle),
                text: $apiKey
            )

            TextField(
                String(localized: "Endpoint URL", bundle: LanguageSettings.currentBundle),
                text: $endpointURL
            )
            #if os(iOS)
            .textInputAutocapitalization(.never)
            .keyboardType(.URL)
            #endif
            .autocorrectionDisabled()

            TextField(
                String(localized: "Model", bundle: LanguageSettings.currentBundle),
                text: $modelName
            )
            #if os(iOS)
            .textInputAutocapitalization(.never)
            #endif
            .autocorrectionDisabled()

            HStack {
                Text(String(localized: "Max Context", bundle: LanguageSettings.currentBundle))
                Spacer()
                TextField("128", value: $maxContextTokensK, format: .number)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
                Text(String(localized: "K tokens", bundle: LanguageSettings.currentBundle))
                    .foregroundStyle(.secondary)
            }

            if apiFormat == .anthropic {
                HStack {
                    Text(String(localized: "Max Output", bundle: LanguageSettings.currentBundle))
                    Spacer()
                    TextField(
                        String(localized: "Auto", bundle: LanguageSettings.currentBundle),
                        text: maxOutputTokensText
                    )
                    .multilineTextAlignment(.trailing)
                    .frame(width: 100)
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
                    Text(String(localized: "tokens", bundle: LanguageSettings.currentBundle))
                        .foregroundStyle(.secondary)
                }
            }

            Picker(
                String(localized: "Thinking Level", bundle: LanguageSettings.currentBundle),
                selection: $thinkingLevel
            ) {
                ForEach(AIThinkingLevel.allCases, id: \.self) { level in
                    Text(verbatim: level.displayName).tag(level)
                }
            }
        } header: {
            Text(String(localized: "AI Service", bundle: LanguageSettings.currentBundle))
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text(
                    String(
                        localized: "Enter the API base URL (e.g. https://api.openai.com/v1). The path will be appended automatically.",
                        bundle: LanguageSettings.currentBundle
                    )
                )
                Text(
                    String(
                        localized: "API key, endpoint, and model are required. Requests go directly to this endpoint; ConchTalk has no managed AI fallback.",
                        bundle: LanguageSettings.currentBundle
                    )
                )
                Text(
                    String(
                        localized: "Thinking Level: “Model Default” sends no thinking parameters. Higher levels can help on hard tasks but respond slower and use more tokens.",
                        bundle: LanguageSettings.currentBundle
                    )
                )
                if apiFormat == .anthropic {
                    Text(
                        String(
                            localized: "Max Output: leave empty to choose automatically by model (32K for Claude 4.6 and newer, 16K for older Claude 4 models, 8K otherwise).",
                            bundle: LanguageSettings.currentBundle
                        )
                    )
                }
                if let window = AnthropicModelCapabilities.contextWindow(for: modelName) {
                    Text(
                        String(
                            format: String(
                                localized: "Max Context: this model has a %@-token context window. Larger values are capped automatically to leave room for the reply.",
                                bundle: LanguageSettings.currentBundle
                            ),
                            DirectContextUsage.compact(window)
                        )
                    )
                }
            }
        }
    }

    /// 最大输出 token 的文本绑定：空串 ↔ 0（自动），只接受数字。
    private var maxOutputTokensText: Binding<String> {
        Binding(
            get: { maxOutputTokens > 0 ? String(maxOutputTokens) : "" },
            set: { newValue in
                let digits = newValue.filter(\.isNumber)
                maxOutputTokens = Int(digits.prefix(7)) ?? 0
            }
        )
    }

    private var permissionLevelSection: some View {
        Section {
            Picker(
                String(localized: "Permission Level", bundle: LanguageSettings.currentBundle),
                selection: $permissionLevel
            ) {
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
            Text(
                String(
                    localized: "Default permission level for all servers. Individual servers can override this.",
                    bundle: LanguageSettings.currentBundle
                )
            )
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
            Button(String(localized: "I Understand the Risks", bundle: LanguageSettings.currentBundle)) {}
            Button(String(localized: "Cancel", bundle: LanguageSettings.currentBundle), role: .cancel) {
                permissionLevel = previousPermissionLevel
            }
        } message: {
            Text(
                String(
                    localized: "Permissive mode auto-executes write commands and allows previously-forbidden destructive commands with confirmation. Only use on trusted or test servers.",
                    bundle: LanguageSettings.currentBundle
                )
            )
        }
    }

    private var saveSection: some View {
        Section {
            Button {
                if saveSettings() {
                    showSaved = true
                }
            } label: {
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
                Button(
                    String(localized: "Discard Changes", bundle: LanguageSettings.currentBundle),
                    role: .destructive
                ) {
                    restoreSavedSettings()
                }
            }
        }
    }

    @discardableResult
    private func saveSettings() -> Bool {
        let webSearchSettings = WebSearchSettings(
            isEnabled: webSearchEnabled,
            provider: webSearchProvider,
            apiKeys: webSearchAPIKeys
        ).trimmingAPIKeys()
        guard !webSearchEnabled || !webSearchSettings.apiKey.isEmpty else {
            showWebSearchKeyRequired = true
            return false
        }

        do {
            try webSearchSettings.save()
        } catch {
            showWebSearchSaveError = true
            return false
        }

        let settings = AISettings(
            apiKey: apiKey,
            endpointURL: endpointURL,
            modelName: modelName,
            maxContextTokensK: max(maxContextTokensK, 1),
            apiFormat: apiFormat,
            permissionLevel: permissionLevel,
            maxOutputTokens: maxOutputTokens > 0 ? max(maxOutputTokens, 1024) : 0,
            thinkingLevel: thinkingLevel
        )
        settings.save()
        savedSettings = settings
        maxOutputTokens = settings.maxOutputTokens
        savedWebSearchSettings = webSearchSettings
        webSearchAPIKeys = webSearchSettings.apiKeys
        reportUnsavedChanges = false
        return true
    }

    private func restoreSavedSettings() {
        apiKey = savedSettings.apiKey
        endpointURL = savedSettings.endpointURL
        modelName = savedSettings.modelName
        maxContextTokensK = savedSettings.maxContextTokensK
        maxOutputTokens = savedSettings.maxOutputTokens
        thinkingLevel = savedSettings.thinkingLevel
        apiFormat = savedSettings.apiFormat
        permissionLevel = savedSettings.permissionLevel
        webSearchEnabled = savedWebSearchSettings.isEnabled
        webSearchProvider = savedWebSearchSettings.provider
        webSearchAPIKeys = savedWebSearchSettings.apiKeys
        reportUnsavedChanges = false
    }
}

#if os(iOS)
/// KeyboardDismissView：通过不拦截点击的手势收起键盘。
private struct KeyboardDismissView: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        let tap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.dismissKeyboard)
        )
        tap.cancelsTouchesInView = false
        view.addGestureRecognizer(tap)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        @objc func dismissKeyboard() {
            UIApplication.shared.sendAction(
                #selector(UIResponder.resignFirstResponder),
                to: nil,
                from: nil,
                for: nil
            )
        }
    }
}
#endif
