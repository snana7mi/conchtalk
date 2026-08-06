/// 文件说明：SSHKeyGenerateView，负责 SSH 密钥生成流程的界面交互。
import SwiftUI

/// SSHKeyGenerateView：以 Sheet 形式引导用户选择密钥类型、输入标签并生成密钥对。
struct SSHKeyGenerateView: View {
    @Environment(\.dismiss) private var dismiss

    let viewModel: SSHKeyManagementViewModel

    @State private var selectedType: SSHKey.KeyType = .ed25519
    @State private var label = ""
    @State private var generatedPublicKey: String?
    @State private var showCopied = false

    /// 可选的密钥类型列表（排除 .unknown）
    private let selectableTypes: [SSHKey.KeyType] = [.ed25519, .rsa4096, .ecdsaP256]

    var body: some View {
        NavigationStack {
            Form {
                Section(String(localized: "Key Type", bundle: LanguageSettings.currentBundle)) {
                    Picker(String(localized: "Type", bundle: LanguageSettings.currentBundle), selection: $selectedType) {
                        Text(String(localized: "Ed25519 (Recommended)", bundle: LanguageSettings.currentBundle)).tag(SSHKey.KeyType.ed25519)
                        Text(String(localized: "RSA 4096", bundle: LanguageSettings.currentBundle)).tag(SSHKey.KeyType.rsa4096)
                        Text(String(localized: "ECDSA P-256", bundle: LanguageSettings.currentBundle)).tag(SSHKey.KeyType.ecdsaP256)
                    }
                }

                Section(String(localized: "Label", bundle: LanguageSettings.currentBundle)) {
                    TextField(String(localized: "e.g. My MacBook", bundle: LanguageSettings.currentBundle), text: $label)
                }

                if let generatedPublicKey {
                    Section {
                        Text(generatedPublicKey)
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
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
            }
            .navigationTitle(String(localized: "Generate SSH Key", bundle: LanguageSettings.currentBundle))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(generatedPublicKey != nil
                        ? String(localized: "Done", bundle: LanguageSettings.currentBundle)
                        : String(localized: "Cancel", bundle: LanguageSettings.currentBundle)
                    ) {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if generatedPublicKey == nil {
                        Button(String(localized: "Generate", bundle: LanguageSettings.currentBundle)) {
                            Task { await generate() }
                        }
                        .disabled(label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || viewModel.isGenerating)
                    }
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
        }
    }

    /// generate：调用 ViewModel 生成密钥并提取公钥用于展示。
    private func generate() async {
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let newKeyID = await viewModel.generateKey(type: selectedType, label: trimmedLabel) else { return }

        // 通过返回的 ID 精确查找刚生成的密钥
        if let newKey = viewModel.keys.first(where: { $0.id == newKeyID }) {
            generatedPublicKey = newKey.publicKeyOpenSSH
        }
    }

    /// copyPublicKey：将生成的公钥复制到系统剪贴板。
    private func copyPublicKey() {
        guard let publicKey = generatedPublicKey else { return }

        UIPasteboard.general.string = publicKey

        showCopied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            showCopied = false
        }
    }
}
