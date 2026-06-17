/// 文件说明:EditDisplayNameView,昵称编辑 sheet,含字数校验、保存中状态与错误提示。
import SwiftUI

struct EditDisplayNameView: View {
    var authService: AuthService
    @Environment(\.dismiss) private var dismiss

    @State private var draft: String
    @State private var isSaving = false
    @State private var errorText: String?

    init(authService: AuthService) {
        self.authService = authService
        _draft = State(initialValue: authService.currentUser?.displayName ?? "")
    }

    private var validated: String? { DisplayNameValidator.validate(draft) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(String(localized: "Nickname", bundle: LanguageSettings.currentBundle), text: $draft)
                        .disabled(isSaving)
                    if let errorText {
                        Text(errorText).foregroundStyle(.red).font(.caption)
                    }
                }
            }
            .navigationTitle(String(localized: "Edit Nickname", bundle: LanguageSettings.currentBundle))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel", bundle: LanguageSettings.currentBundle)) { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button(String(localized: "Save", bundle: LanguageSettings.currentBundle)) { Task { await save() } }
                            .disabled(validated == nil)
                    }
                }
            }
        }
    }

    private func save() async {
        guard let name = validated else {
            errorText = String(localized: "Nickname must be 1–24 characters.", bundle: LanguageSettings.currentBundle)
            return
        }
        isSaving = true
        defer { isSaving = false }
        do {
            try await authService.updateDisplayName(name)
            dismiss()
        } catch {
            errorText = String(localized: "Failed to update nickname: \(error.localizedDescription)", bundle: LanguageSettings.currentBundle)
        }
    }
}
