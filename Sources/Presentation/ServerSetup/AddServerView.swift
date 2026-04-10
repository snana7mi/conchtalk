/// 文件说明：AddServerView，负责服务器配置与 SSH 密钥导入流程。
import SwiftUI
import PhotosUI
import UIKit

enum ServerCredentialField: CaseIterable {
    case name
    case host
    case port
    case username
    case password

    var textContentType: UITextContentType? {
        switch self {
        case .username, .password:
            .oneTimeCode
        case .name, .host, .port:
            nil
        }
    }
}

private struct ServerCredentialTextField: UIViewRepresentable {
    let title: String
    @Binding var text: String
    let field: ServerCredentialField
    let isSecure: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeUIView(context: Context) -> UITextField {
        let textField = UITextField(frame: .zero)
        textField.placeholder = title
        textField.delegate = context.coordinator
        textField.text = text
        textField.isSecureTextEntry = isSecure
        textField.textContentType = field.textContentType
        textField.passwordRules = nil
        textField.autocapitalizationType = .none
        textField.autocorrectionType = .no
        textField.spellCheckingType = .no
        textField.smartDashesType = .no
        textField.smartQuotesType = .no
        textField.smartInsertDeleteType = .no
        textField.clearButtonMode = .never
        textField.borderStyle = .none
        textField.adjustsFontForContentSizeCategory = true
        textField.font = UIFont.preferredFont(forTextStyle: .body)
        textField.backgroundColor = .clear
        textField.keyboardType = isSecure ? .asciiCapable : .default
        textField.addTarget(context.coordinator, action: #selector(Coordinator.textChanged(_:)), for: .editingChanged)
        return textField
    }

    func updateUIView(_ uiView: UITextField, context: Context) {
        if uiView.text != text {
            uiView.text = text
        }
        if uiView.isSecureTextEntry != isSecure {
            uiView.isSecureTextEntry = isSecure
        }
        uiView.placeholder = title
        uiView.textContentType = field.textContentType
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        @Binding private var text: String

        init(text: Binding<String>) {
            _text = text
        }

        @objc func textChanged(_ sender: UITextField) {
            text = sender.text ?? ""
        }
    }
}

/// AddServerView：负责界面渲染与用户交互响应。
struct AddServerView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var host = ""
    @State private var port = "22"
    @State private var username = "root"
    @State private var authType: AuthType = .password
    @State private var password = ""
    @State private var selectedKeyID: UUID?
    @State private var selectedGroupID: UUID?
    @State private var iconItem: PhotosPickerItem?
    @State private var iconData: Data?
    @State private var iconPreviewImage: Image?
    @State private var serverPermissionLevel: ServerPermissionLevel = .followGlobal
    @State private var dlcOverride: DLCOverrideOption = .followGlobal
    @State private var showPermissiveWarning = false
    @State private var connectionMode: ServerConnectionMode = .direct
    @State private var relayInstallCommand: String? = nil
    @State private var isGeneratingToken: Bool = false
    @State private var hasExpiration = false
    @State private var expirationDate = Calendar.current.date(byAdding: .month, value: 1, to: Date()) ?? Date()
    @State private var previousPermissionLevel: ServerPermissionLevel = .followGlobal
    @State private var globalPermissionLevel: PermissionLevel

    let groups: [ServerGroup]
    let availableKeys: [SSHKey]
    let keychainService: any KeychainServiceProtocol
    let relayTokenService: RelayTokenService?
    let authService: AuthServiceProtocol?
    let onSave: (Server, String?, UUID?) -> Void

    /// The server being edited, nil for add mode.
    private let editingServer: Server?

    /// AuthType：定义服务器连接时可选的认证方式。
    enum AuthType: CaseIterable {
        case password
        case privateKey

        var displayName: String {
            switch self {
            case .password: String(localized: "Password", bundle: LanguageSettings.currentBundle)
            case .privateKey: String(localized: "SSH Key", bundle: LanguageSettings.currentBundle)
            }
        }
    }

    /// DLCOverrideOption：服务器级别 DLC Agent 覆盖选项。
    private enum DLCOverrideOption: String, CaseIterable {
        case followGlobal
        case enabled
        case disabled

        var displayName: String {
            switch self {
            case .followGlobal: String(localized: "Follow Global", bundle: LanguageSettings.currentBundle)
            case .enabled: String(localized: "Enabled", bundle: LanguageSettings.currentBundle)
            case .disabled: String(localized: "Disabled", bundle: LanguageSettings.currentBundle)
            }
        }
    }

    private var isEditing: Bool { editingServer != nil }

    /// 初始化服务器配置表单并注入回调。
    init(groups: [ServerGroup], availableKeys: [SSHKey], keychainService: any KeychainServiceProtocol, relayTokenService: RelayTokenService? = nil, authService: AuthServiceProtocol? = nil, onSave: @escaping (Server, String?, UUID?) -> Void) {
        self.groups = groups
        self.availableKeys = availableKeys
        self.keychainService = keychainService
        self.relayTokenService = relayTokenService
        self.authService = authService
        self.onSave = onSave
        self.editingServer = nil
        _globalPermissionLevel = State(initialValue: AISettings.load().permissionLevel)
    }

    /// 初始化服务器配置表单并注入回调。
    init(editing server: Server, groups: [ServerGroup], availableKeys: [SSHKey], keychainService: any KeychainServiceProtocol, relayTokenService: RelayTokenService? = nil, authService: AuthServiceProtocol? = nil, onSave: @escaping (Server, String?, UUID?) -> Void) {
        self.groups = groups
        self.availableKeys = availableKeys
        self.keychainService = keychainService
        self.relayTokenService = relayTokenService
        self.authService = authService
        self.onSave = onSave
        self.editingServer = server
        _connectionMode = State(initialValue: server.connectionMode)
        _name = State(initialValue: server.name)
        _host = State(initialValue: server.host)
        _port = State(initialValue: String(server.port))
        _username = State(initialValue: server.username)
        _selectedGroupID = State(initialValue: server.groupID)
        _iconData = State(initialValue: server.iconData)
        if let data = server.iconData, let img = ImageUtils.makeSwiftUIImage(from: data) {
            _iconPreviewImage = State(initialValue: img)
        }
        _serverPermissionLevel = State(initialValue: server.permissionLevel)
        _globalPermissionLevel = State(initialValue: AISettings.load().permissionLevel)
        if let expDate = server.expirationDate {
            _hasExpiration = State(initialValue: true)
            _expirationDate = State(initialValue: expDate)
        }
        switch server.authMethod {
        case .password:
            _authType = State(initialValue: .password)
            let existingPassword = (try? keychainService.getPassword(forServer: server.id)) ?? ""
            _password = State(initialValue: existingPassword)
        case .privateKey(let keyID):
            _authType = State(initialValue: .privateKey)
            _selectedKeyID = State(initialValue: UUID(uuidString: keyID))
        }
        // 加载服务器级别 DLC override
        if let override = DLCSettings.serverOverride(for: server.id) {
            _dlcOverride = State(initialValue: override ? .enabled : .disabled)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Spacer()
                        PhotosPicker(selection: $iconItem, matching: .images) {
                            ZStack {
                                if let iconPreviewImage {
                                    iconPreviewImage
                                        .resizable()
                                        .scaledToFill()
                                } else {
                                    RoundedRectangle(cornerRadius: 12)
                                        .fill(Color.secondary.opacity(0.15))
                                    Image(systemName: "photo.badge.plus")
                                        .font(.title2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(width: 72, height: 72)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                }
                .onChange(of: iconItem) {
                    guard let iconItem else { return }
                    Task { await handleIconSelection(iconItem) }
                }

                // 连接方式选择
                Section {
                    Picker(String(localized: "Connection Mode", bundle: LanguageSettings.currentBundle), selection: $connectionMode) {
                        Text(String(localized: "Direct SSH", bundle: LanguageSettings.currentBundle))
                            .tag(ServerConnectionMode.direct)
                        HStack {
                            Text(String(localized: "Relay", bundle: LanguageSettings.currentBundle))
                            Text("PRO")
                                .font(.caption2.bold())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.blue)
                                .foregroundStyle(.white)
                                .clipShape(Capsule())
                        }
                        .tag(ServerConnectionMode.relay)
                    }
                    .onChange(of: connectionMode) { _, newValue in
                        if newValue == .relay && authService?.currentUser?.tier != "paid" {
                            connectionMode = .direct
                        }
                    }
                } header: {
                    Text(String(localized: "Connection", bundle: LanguageSettings.currentBundle))
                }

                // Relay 配置
                if connectionMode == .relay {
                    Section {
                        TextField(String(localized: "Name", bundle: LanguageSettings.currentBundle), text: $name)

                        if let command = relayInstallCommand {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(String(localized: "Install daemon on your server:", bundle: LanguageSettings.currentBundle))
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)

                                Text(command)
                                    .font(.system(.caption, design: .monospaced))
                                    .padding(12)
                                    .background(Color.secondary.opacity(0.1))
                                    .clipShape(RoundedRectangle(cornerRadius: 8))

                                Button(String(localized: "Copy Command", bundle: LanguageSettings.currentBundle)) {
                                    UIPasteboard.general.string = command
                                }
                                .buttonStyle(.bordered)
                            }
                        } else {
                            Button {
                                Task { await generateRelayToken() }
                            } label: {
                                if isGeneratingToken {
                                    ProgressView()
                                } else {
                                    Text(String(localized: "Generate Token", bundle: LanguageSettings.currentBundle))
                                }
                            }
                            .disabled(isGeneratingToken || name.isEmpty)
                        }
                    } header: {
                        Text(String(localized: "Relay Setup", bundle: LanguageSettings.currentBundle))
                    }
                }

                if connectionMode == .direct {
                Section(String(localized: "Server Info", bundle: LanguageSettings.currentBundle)) {
                    TextField(String(localized: "Name", bundle: LanguageSettings.currentBundle), text: $name)
                    TextField(String(localized: "Host", bundle: LanguageSettings.currentBundle), text: $host)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                    TextField(String(localized: "Port", bundle: LanguageSettings.currentBundle), text: $port)
                        .keyboardType(.numberPad)
                    ServerCredentialTextField(
                        title: String(localized: "Username", bundle: LanguageSettings.currentBundle),
                        text: $username,
                        field: .username,
                        isSecure: false
                    )
                    .privacySensitive()
                }

                Section(String(localized: "Authentication", bundle: LanguageSettings.currentBundle)) {
                    Picker(String(localized: "Method", bundle: LanguageSettings.currentBundle), selection: $authType) {
                        ForEach(AuthType.allCases, id: \.self) { type in
                            Text(verbatim: type.displayName).tag(type)
                        }
                    }
                    .pickerStyle(.segmented)

                    switch authType {
                    case .password:
                        ServerCredentialTextField(
                            title: String(localized: "Password", bundle: LanguageSettings.currentBundle),
                            text: $password,
                            field: .password,
                            isSecure: true
                        )
                        .privacySensitive()
                    case .privateKey:
                        Picker(String(localized: "SSH Key", bundle: LanguageSettings.currentBundle), selection: $selectedKeyID) {
                            Text(String(localized: "Select a key", bundle: LanguageSettings.currentBundle)).tag(nil as UUID?)
                            ForEach(availableKeys) { key in
                                HStack {
                                    Text(key.label)
                                    Text("(\(key.keyType.displayName))")
                                        .foregroundStyle(.secondary)
                                }
                                .tag(key.id as UUID?)
                            }
                        }

                        if availableKeys.isEmpty {
                            Text(String(localized: "No keys available. Go to Settings → SSH Keys to add one.", bundle: LanguageSettings.currentBundle))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                } // end if connectionMode == .direct

                Section(String(localized: "Group", bundle: LanguageSettings.currentBundle)) {
                    Picker(String(localized: "Group", bundle: LanguageSettings.currentBundle), selection: $selectedGroupID) {
                        Text(String(localized: "None", bundle: LanguageSettings.currentBundle)).tag(nil as UUID?)
                        ForEach(groups) { group in
                            Text(group.name).tag(group.id as UUID?)
                        }
                    }
                }
                Section {
                    Picker(String(localized: "Permission Level", bundle: LanguageSettings.currentBundle), selection: $serverPermissionLevel) {
                        ForEach(ServerPermissionLevel.allCases, id: \.self) { level in
                            Text(verbatim: level.displayName).tag(level)
                        }
                    }

                    if serverPermissionLevel == .followGlobal {
                        Label {
                            Text(String(localized: "Current: \(globalPermissionLevel.displayName)", bundle: LanguageSettings.currentBundle))
                        } icon: {
                            Image(systemName: globalPermissionLevel.iconName)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                } header: {
                    Text(String(localized: "Permission Level", bundle: LanguageSettings.currentBundle))
                }
                Section {
                    Picker(String(localized: "DLC Agent", bundle: LanguageSettings.currentBundle), selection: $dlcOverride) {
                        ForEach(DLCOverrideOption.allCases, id: \.self) { option in
                            Text(verbatim: option.displayName).tag(option)
                        }
                    }
                    .disabled(AISettings.load().useLocalConfig)

                    if AISettings.load().useLocalConfig {
                        Label(
                            String(localized: "DLC Agent requires built-in AI model", bundle: LanguageSettings.currentBundle),
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                } header: {
                    Text(String(localized: "DLC Agent", bundle: LanguageSettings.currentBundle))
                }
                Section {
                    Toggle(String(localized: "Expiration", bundle: LanguageSettings.currentBundle), isOn: $hasExpiration)

                    if hasExpiration {
                        DatePicker(
                            String(localized: "Expiration Date", bundle: LanguageSettings.currentBundle),
                            selection: $expirationDate,
                            in: Calendar.current.date(byAdding: .day, value: 1, to: Date())!...,
                            displayedComponents: .date
                        )

                        Text(String(localized: "Server and all data will be automatically deleted after expiration.", bundle: LanguageSettings.currentBundle))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text(String(localized: "Expiration", bundle: LanguageSettings.currentBundle))
                }
            }
            .onChange(of: serverPermissionLevel) { oldValue, newValue in
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
                    serverPermissionLevel = previousPermissionLevel
                }
            } message: {
                Text(String(localized: "Permissive mode auto-executes write commands and allows previously-forbidden destructive commands with confirmation. Only use on trusted or test servers.", bundle: LanguageSettings.currentBundle))
            }
            .navigationTitle(isEditing
                ? String(localized: "Edit Server", bundle: LanguageSettings.currentBundle)
                : String(localized: "Add Server", bundle: LanguageSettings.currentBundle))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel", bundle: LanguageSettings.currentBundle)) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Save", bundle: LanguageSettings.currentBundle)) { saveServer() }
                        .disabled(!isValid)
                }
            }
        }
    }

    private var isValid: Bool {
        if connectionMode == .relay {
            return !name.isEmpty
        }
        return !name.isEmpty && !host.isEmpty && !username.isEmpty && !port.isEmpty &&
        (authType == .password ? !password.isEmpty :
            selectedKeyID != nil && availableKeys.contains(where: { $0.id == selectedKeyID }))
    }

    private func handleIconSelection(_ item: PhotosPickerItem) async {
        defer { iconItem = nil }
        guard let data = try? await item.loadTransferable(type: Data.self) else { return }
        guard let compressed = ImageUtils.compressImage(data, maxSize: 256) else { return }
        iconData = compressed
        iconPreviewImage = ImageUtils.makeSwiftUIImage(from: compressed)
    }

    /// saveServer：保存当前数据变更到持久层。
    private func saveServer() {
        let portNum = Int(port) ?? 22

        let authMethod: Server.AuthMethod
        var pwd: String? = nil

        switch authType {
        case .password:
            authMethod = .password
            pwd = password
        case .privateKey:
            guard let selectedKeyID, availableKeys.contains(where: { $0.id == selectedKeyID }) else { return }
            let keyID = selectedKeyID.uuidString
            authMethod = .privateKey(keyID: keyID)
            // 密钥数据与口令均在 SSH Keys 管理页面维护，此处不做任何 Keychain 操作
        }

        let serverID = editingServer?.id ?? UUID()
        let server = Server(
            id: serverID,
            name: name,
            host: connectionMode == .relay ? "relay" : host,
            port: portNum,
            username: connectionMode == .relay ? "relay" : username,
            authMethod: authMethod,
            groupID: selectedGroupID,
            countryCode: editingServer?.countryCode,
            iconData: iconData,
            permissionLevel: serverPermissionLevel,
            expirationDate: hasExpiration ? expirationDate : nil,
            connectionMode: connectionMode
        )
        onSave(server, pwd, selectedGroupID)

        // 持久化 DLC override
        switch dlcOverride {
        case .followGlobal:
            DLCSettings.clearServerOverride(for: server.id)
        case .enabled:
            DLCSettings.setServerOverride(for: server.id, enabled: true)
        case .disabled:
            DLCSettings.setServerOverride(for: server.id, enabled: false)
        }

        dismiss()
    }

    /// 生成 relay daemon token。
    private func generateRelayToken() async {
        guard let service = relayTokenService else { return }
        isGeneratingToken = true
        defer { isGeneratingToken = false }

        do {
            let serverID = editingServer?.id ?? UUID()
            let response = try await service.createToken(
                serverID: serverID,
                name: name.isEmpty ? nil : name
            )
            relayInstallCommand = response.installCommand
        } catch {
            // token 生成失败，静默处理
        }
    }
}
