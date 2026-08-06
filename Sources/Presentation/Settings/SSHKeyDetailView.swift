/// 文件说明：SSHKeyDetailView，负责展示单个 SSH 密钥的详细信息与操作。
import SwiftUI
import UniformTypeIdentifiers

/// SSHKeyDetailView：展示密钥详情，支持编辑标签、替换密钥、复制公钥及删除操作。
struct SSHKeyDetailView: View {
    let viewModel: SSHKeyManagementViewModel

    @Environment(\.dismiss) private var dismiss

    @State private var key: SSHKey
    @State private var editedLabel: String
    @State private var serversUsingKey: [Server] = []
    @State private var showDeleteConfirmation = false
    @State private var showCopied = false
    @State private var showReplaceSheet = false

    /// 初始化密钥详情视图。
    init(key: SSHKey, viewModel: SSHKeyManagementViewModel) {
        self.viewModel = viewModel
        _key = State(initialValue: key)
        _editedLabel = State(initialValue: key.label)
    }

    var body: some View {
        Form {
            Section(String(localized: "Key Info", bundle: LanguageSettings.currentBundle)) {
                LabeledContent(String(localized: "Type", bundle: LanguageSettings.currentBundle), value: key.keyType.displayName)
                LabeledContent(String(localized: "Source", bundle: LanguageSettings.currentBundle)) {
                    Label(
                        key.source == .generated
                            ? String(localized: "Generated", bundle: LanguageSettings.currentBundle)
                            : String(localized: "Imported", bundle: LanguageSettings.currentBundle),
                        systemImage: key.source == .generated ? "wand.and.stars" : "square.and.arrow.down"
                    )
                }
                LabeledContent(String(localized: "Created", bundle: LanguageSettings.currentBundle), value: key.createdAt, format: .dateTime)
            }

            Section(String(localized: "Label", bundle: LanguageSettings.currentBundle)) {
                TextField(String(localized: "Label", bundle: LanguageSettings.currentBundle), text: $editedLabel)
                    .onSubmit {
                        Task {
                            await viewModel.updateLabel(key, newLabel: editedLabel)
                        }
                    }
            }

            if !key.fingerprint.isEmpty {
                Section(String(localized: "Fingerprint", bundle: LanguageSettings.currentBundle)) {
                    Text(key.fingerprint)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
            }

            if !key.publicKeyOpenSSH.isEmpty {
                Section {
                    Text(key.publicKeyOpenSSH)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(4)
                } header: {
                    HStack {
                        Text(String(localized: "Public Key", bundle: LanguageSettings.currentBundle))
                        Spacer()
                        Button(showCopied
                            ? String(localized: "Copied!", bundle: LanguageSettings.currentBundle)
                            : String(localized: "Copy", bundle: LanguageSettings.currentBundle)
                        ) {
                            copyPublicKey()
                        }
                        .font(.caption)
                    }
                } footer: {
                    Text(String(localized: "Add this public key to your server's ~/.ssh/authorized_keys", bundle: LanguageSettings.currentBundle))
                }
            }

            Section {
                Button {
                    showReplaceSheet = true
                } label: {
                    Label(String(localized: "Replace Private Key", bundle: LanguageSettings.currentBundle), systemImage: "arrow.triangle.2.circlepath")
                }
            } footer: {
                Text(String(localized: "Replace the private key data while keeping the same key ID. All servers using this key will use the new key on next connection.", bundle: LanguageSettings.currentBundle))
            }

            Section(String(localized: "Servers Using This Key", bundle: LanguageSettings.currentBundle)) {
                if serversUsingKey.isEmpty {
                    Text(String(localized: "No servers using this key", bundle: LanguageSettings.currentBundle))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(serversUsingKey) { server in
                        Text(server.name)
                    }
                }
            }

            Section {
                Button(String(localized: "Delete Key", bundle: LanguageSettings.currentBundle), role: .destructive) {
                    showDeleteConfirmation = true
                }
            }
        }
        .navigationTitle(key.label)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showReplaceSheet) {
            ReplaceKeySheetView(key: key, viewModel: viewModel) { updatedKey in
                key = updatedKey
            }
        }
        .alert(String(localized: "Delete Key", bundle: LanguageSettings.currentBundle), isPresented: $showDeleteConfirmation) {
            Button(String(localized: "Cancel", bundle: LanguageSettings.currentBundle), role: .cancel) {}
            Button(String(localized: "Delete", bundle: LanguageSettings.currentBundle), role: .destructive) {
                Task {
                    await viewModel.deleteKey(key)
                    dismiss()
                }
            }
        } message: {
            if serversUsingKey.isEmpty {
                Text(String(localized: "Are you sure you want to delete \"\(key.label)\"? This action cannot be undone.", bundle: LanguageSettings.currentBundle))
            } else {
                Text(String(localized: "Warning: \(serversUsingKey.count) server(s) are using this key. Deleting it may break their SSH connections.", bundle: LanguageSettings.currentBundle))
            }
        }
        .alert(String(localized: "Error", bundle: LanguageSettings.currentBundle), isPresented: Binding(
            get: { viewModel.showError },
            set: { viewModel.showError = $0 }
        )) {
            Button(String(localized: "OK", bundle: LanguageSettings.currentBundle), role: .cancel) {}
        } message: {
            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
            }
        }
        .task {
            serversUsingKey = await viewModel.serversUsingKey(key.id)
        }
    }

    /// copyPublicKey：将公钥复制到系统剪贴板并短暂显示确认提示。
    private func copyPublicKey() {
        UIPasteboard.general.string = key.publicKeyOpenSSH

        showCopied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            showCopied = false
        }
    }
}

// MARK: - 替换密钥的内嵌 Sheet 视图

/// ReplaceKeySheetView：以 Sheet 形式引导用户替换已有密钥的私钥数据。
private struct ReplaceKeySheetView: View {
    @Environment(\.dismiss) private var dismiss

    let key: SSHKey
    let viewModel: SSHKeyManagementViewModel
    let onReplaced: (SSHKey) -> Void

    @State private var keyText = ""
    @State private var passphrase = ""
    @State private var showFilePicker = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $keyText)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 120)

                    Button {
                        showFilePicker = true
                    } label: {
                        Label(String(localized: "Import from File", bundle: LanguageSettings.currentBundle), systemImage: "doc")
                    }
                } header: {
                    Text(String(localized: "New Private Key", bundle: LanguageSettings.currentBundle))
                } footer: {
                    Text(String(localized: "Paste the new SSH private key or import from a file. The key ID remains unchanged — all servers using this key will automatically use the new key.", bundle: LanguageSettings.currentBundle))
                }

                Section(String(localized: "Passphrase (Optional)", bundle: LanguageSettings.currentBundle)) {
                    SecureField(String(localized: "Passphrase", bundle: LanguageSettings.currentBundle), text: $passphrase)
                }
            }
            .navigationTitle(String(localized: "Replace Key", bundle: LanguageSettings.currentBundle))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel", bundle: LanguageSettings.currentBundle)) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Replace", bundle: LanguageSettings.currentBundle)) {
                        Task {
                            let pw = passphrase.isEmpty ? nil : passphrase
                            if let updated = await viewModel.replaceKey(key, newPrivateKeyText: keyText, passphrase: pw) {
                                onReplaced(updated)
                            }
                            dismiss()
                        }
                    }
                    .disabled(keyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.data, .text]) { result in
                if case .success(let url) = result {
                    if url.startAccessingSecurityScopedResource() {
                        defer { url.stopAccessingSecurityScopedResource() }
                        if let data = try? Data(contentsOf: url),
                           let text = String(data: data, encoding: .utf8) {
                            keyText = text
                        }
                    }
                }
            }
        }
    }
}
