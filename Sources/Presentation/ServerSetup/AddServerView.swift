/// 文件说明：AddServerView，负责服务器配置与 SSH 密钥导入流程。
import SwiftUI

/// AddServerView：负责界面渲染与用户交互响应。
struct AddServerView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var host = ""
    @State private var port = "22"
    @State private var username = "root"
    @State private var authType: AuthType = .password
    @State private var password = ""
    @State private var sshKeyText = ""
    @State private var keyPassphrase = ""
    @State private var showKeyImport = false
    @State private var selectedGroupID: UUID?

    let groups: [ServerGroup]
    let onSave: (Server, String?, UUID?) -> Void

    /// The server being edited, nil for add mode.
    private let editingServer: Server?

    /// AuthType：定义服务器连接时可选的认证方式。
    enum AuthType: CaseIterable {
        case password
        case privateKey

        var displayName: LocalizedStringResource {
            switch self {
            case .password: "Password"
            case .privateKey: "SSH Key"
            }
        }
    }

    private var isEditing: Bool { editingServer != nil }

    /// 初始化服务器配置表单并注入回调。
    init(groups: [ServerGroup], onSave: @escaping (Server, String?, UUID?) -> Void) {
        self.groups = groups
        self.onSave = onSave
        self.editingServer = nil
    }

    /// 初始化服务器配置表单并注入回调。
    init(editing server: Server, groups: [ServerGroup], onSave: @escaping (Server, String?, UUID?) -> Void) {
        self.groups = groups
        self.onSave = onSave
        self.editingServer = server
        _name = State(initialValue: server.name)
        _host = State(initialValue: server.host)
        _port = State(initialValue: String(server.port))
        _username = State(initialValue: server.username)
        _selectedGroupID = State(initialValue: server.groupID)
        switch server.authMethod {
        case .password:
            _authType = State(initialValue: .password)
            let keychain = KeychainService()
            let existingPassword = (try? keychain.getPassword(forServer: server.id)) ?? ""
            _password = State(initialValue: existingPassword)
        case .privateKey(let keyID):
            _authType = State(initialValue: .privateKey)
            _sshKeyText = State(initialValue: "(existing key)")
            let keychain = KeychainService()
            let existingPassphrase = (try? keychain.getKeyPassphrase(forKeyID: keyID)) ?? ""
            _keyPassphrase = State(initialValue: existingPassphrase)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Server Info") {
                    TextField("Name", text: $name)
                    TextField("Host", text: $host)
                        #if os(iOS)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        #endif
                    TextField("Port", text: $port)
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif
                    TextField("Username", text: $username)
                        #if os(iOS)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        #endif
                }

                Section("Authentication") {
                    Picker("Method", selection: $authType) {
                        ForEach(AuthType.allCases, id: \.self) { type in
                            Text(String(localized: type.displayName)).tag(type)
                        }
                    }
                    .pickerStyle(.segmented)

                    switch authType {
                    case .password:
                        SecureField("Password", text: $password)
                            #if os(iOS)
                            .textContentType(.password)
                            #endif
                    case .privateKey:
                        Button("Import SSH Key") {
                            showKeyImport = true
                        }
                        if !sshKeyText.isEmpty {
                            Label("Key imported", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                        SecureField("Key Passphrase (optional)", text: $keyPassphrase)
                            #if os(iOS)
                            .textContentType(.password)
                            #endif
                    }
                }

                Section("Group") {
                    Picker("Group", selection: $selectedGroupID) {
                        Text("None").tag(nil as UUID?)
                        ForEach(groups) { group in
                            Text(group.name).tag(group.id as UUID?)
                        }
                    }
                }
            }
            .navigationTitle(isEditing ? "Edit Server" : "Add Server")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { saveServer() }
                        .disabled(!isValid)
                }
            }
            .sheet(isPresented: $showKeyImport) {
                SSHKeyImportView { keyText in
                    sshKeyText = keyText
                }
            }
        }
    }

    private var isValid: Bool {
        !name.isEmpty && !host.isEmpty && !username.isEmpty && !port.isEmpty &&
        (authType == .password ? !password.isEmpty : !sshKeyText.isEmpty)
    }

    /// saveServer：保存当前数据变更到持久层。
    private func saveServer() {
        let portNum = Int(port) ?? 22
        let existingKeyID: String? = if case .privateKey(let keyID) = editingServer?.authMethod { keyID } else { nil }
        let keyID = existingKeyID ?? UUID().uuidString

        let authMethod: Server.AuthMethod
        var pwd: String? = nil

        switch authType {
        case .password:
            authMethod = .password
            pwd = password
        case .privateKey:
            authMethod = .privateKey(keyID: keyID)
            let keychain = KeychainService()
            // Save key to keychain only if user imported a new key
            if sshKeyText != "(existing key)", let keyData = sshKeyText.data(using: .utf8) {
                try? keychain.saveSSHKey(keyData, withID: keyID)
            }
            // Save passphrase (or clear it if empty)
            if !keyPassphrase.isEmpty {
                try? keychain.saveKeyPassphrase(keyPassphrase, forKeyID: keyID)
            } else {
                try? keychain.deleteKeyPassphrase(forKeyID: keyID)
            }
        }

        let serverID = editingServer?.id ?? UUID()
        let server = Server(
            id: serverID,
            name: name,
            host: host,
            port: portNum,
            username: username,
            authMethod: authMethod,
            groupID: selectedGroupID
        )
        onSave(server, pwd, selectedGroupID)
        dismiss()
    }
}
