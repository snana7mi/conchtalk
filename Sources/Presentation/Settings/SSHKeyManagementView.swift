/// 文件说明：SSHKeyManagementView，负责 SSH 密钥列表展示与增删操作。
import SwiftUI
import UniformTypeIdentifiers

/// SSHKeyManagementView：展示所有已管理的 SSH 密钥，支持生成、导入和删除操作。
struct SSHKeyManagementView: View {
    @State var viewModel: SSHKeyManagementViewModel

    @State private var showGenerateSheet = false
    @State private var showImportSheet = false
    @State private var showDeleteConfirmation = false
    @State private var keyToDelete: SSHKey?
    @State private var serversUsingDeleteKey: [Server] = []
    @State private var showRenameAlert = false
    @State private var keyToRename: SSHKey?
    @State private var renameText = ""

    var body: some View {
        List {
            ForEach(viewModel.keys) { key in
                NavigationLink {
                    SSHKeyDetailView(key: key, viewModel: viewModel)
                } label: {
                    keyRow(key)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        keyToDelete = key
                        Task {
                            serversUsingDeleteKey = await viewModel.serversUsingKey(key.id)
                            showDeleteConfirmation = true
                        }
                    } label: {
                        Label(String(localized: "Delete", bundle: LanguageSettings.currentBundle), systemImage: "trash")
                    }
                    Button {
                        keyToRename = key
                        renameText = key.label
                        showRenameAlert = true
                    } label: {
                        Label(String(localized: "Rename", bundle: LanguageSettings.currentBundle), systemImage: "pencil")
                    }
                    .tint(.blue)
                }
            }
        }
        .navigationTitle(String(localized: "SSH Keys", bundle: LanguageSettings.currentBundle))
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Menu {
                    Button {
                        showGenerateSheet = true
                    } label: {
                        Label(String(localized: "Generate New Key", bundle: LanguageSettings.currentBundle), systemImage: "wand.and.stars")
                    }
                    Button {
                        showImportSheet = true
                    } label: {
                        Label(String(localized: "Import Key", bundle: LanguageSettings.currentBundle), systemImage: "square.and.arrow.down")
                    }
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showGenerateSheet) {
            SSHKeyGenerateView(viewModel: viewModel)
        }
        .sheet(isPresented: $showImportSheet) {
            SSHKeyImportSheetView(viewModel: viewModel)
        }
        .alert(String(localized: "Delete Key", bundle: LanguageSettings.currentBundle), isPresented: $showDeleteConfirmation, presenting: keyToDelete) { key in
            Button(String(localized: "Cancel", bundle: LanguageSettings.currentBundle), role: .cancel) {
                keyToDelete = nil
            }
            Button(String(localized: "Delete", bundle: LanguageSettings.currentBundle), role: .destructive) {
                Task {
                    await viewModel.deleteKey(key)
                    keyToDelete = nil
                }
            }
        } message: { key in
            if serversUsingDeleteKey.isEmpty {
                Text(String(localized: "Are you sure you want to delete \"\(key.label)\"? This action cannot be undone.", bundle: LanguageSettings.currentBundle))
            } else {
                let names = serversUsingDeleteKey.map(\.name).joined(separator: ", ")
                Text(String(localized: "Warning: \(serversUsingDeleteKey.count) server(s) are using this key (\(names)). Deleting it will break their SSH connections.", bundle: LanguageSettings.currentBundle))
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
        .alert(String(localized: "Rename", bundle: LanguageSettings.currentBundle), isPresented: $showRenameAlert) {
            TextField(String(localized: "Label", bundle: LanguageSettings.currentBundle), text: $renameText)
            Button(String(localized: "Cancel", bundle: LanguageSettings.currentBundle), role: .cancel) {
                keyToRename = nil
            }
            Button(String(localized: "Save", bundle: LanguageSettings.currentBundle)) {
                if let key = keyToRename {
                    Task {
                        await viewModel.updateLabel(key, newLabel: renameText)
                    }
                }
                keyToRename = nil
            }
            .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text(String(localized: "Enter a new label for this key.", bundle: LanguageSettings.currentBundle))
        }
        .overlay {
            if viewModel.keys.isEmpty {
                ContentUnavailableView {
                    Label(String(localized: "No SSH Keys", bundle: LanguageSettings.currentBundle), systemImage: "key")
                } description: {
                    Text(String(localized: "Generate a new key or import an existing one to get started.", bundle: LanguageSettings.currentBundle))
                }
            }
        }
        .task {
            await viewModel.loadKeys()
        }
    }

    /// keyRow：渲染单个密钥行的标签、类型徽章和指纹信息。
    @ViewBuilder
    private func keyRow(_ key: SSHKey) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(key.label)
                    .font(.headline)
                Spacer()
                Text(key.keyType.displayName)
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.2))
                    .clipShape(Capsule())
            }
            if !key.fingerprint.isEmpty {
                Text(key.fingerprint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            HStack {
                Image(systemName: key.source == .generated ? "wand.and.stars" : "square.and.arrow.down")
                    .font(.caption2)
                Text(key.createdAt, style: .date)
                    .font(.caption2)
            }
            .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - 导入密钥的内嵌 Sheet 视图

/// SSHKeyImportSheetView：以 Sheet 形式展示密钥导入表单，支持粘贴或从文件导入。
private struct SSHKeyImportSheetView: View {
    @Environment(\.dismiss) private var dismiss

    let viewModel: SSHKeyManagementViewModel

    @State private var importLabel = ""
    @State private var importKeyText = ""
    @State private var importPassphrase = ""
    @State private var showFilePicker = false

    var body: some View {
        NavigationStack {
            Form {
                Section(String(localized: "Label", bundle: LanguageSettings.currentBundle)) {
                    TextField(String(localized: "e.g. My Server Key", bundle: LanguageSettings.currentBundle), text: $importLabel)
                }

                Section {
                    TextEditor(text: $importKeyText)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 120)

                    Button {
                        showFilePicker = true
                    } label: {
                        Label(String(localized: "Import from File", bundle: LanguageSettings.currentBundle), systemImage: "doc")
                    }
                } header: {
                    Text(String(localized: "Private Key", bundle: LanguageSettings.currentBundle))
                } footer: {
                    Text(String(localized: "Paste your SSH private key or import from a file.", bundle: LanguageSettings.currentBundle))
                }

                Section(String(localized: "Passphrase (Optional)", bundle: LanguageSettings.currentBundle)) {
                    SecureField(String(localized: "Passphrase", bundle: LanguageSettings.currentBundle), text: $importPassphrase)
                }
            }
            .navigationTitle(String(localized: "Import SSH Key", bundle: LanguageSettings.currentBundle))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel", bundle: LanguageSettings.currentBundle)) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Import", bundle: LanguageSettings.currentBundle)) {
                        Task {
                            let passphrase = importPassphrase.isEmpty ? nil : importPassphrase
                            await viewModel.importKey(
                                privateKeyText: importKeyText,
                                passphrase: passphrase,
                                label: importLabel
                            )
                            dismiss()
                        }
                    }
                    .disabled(importLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                              importKeyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.data, .text]) { result in
                if case .success(let url) = result {
                    if url.startAccessingSecurityScopedResource() {
                        defer { url.stopAccessingSecurityScopedResource() }
                        if let data = try? Data(contentsOf: url),
                           let text = String(data: data, encoding: .utf8) {
                            importKeyText = text
                        }
                    }
                }
            }
        }
    }
}
