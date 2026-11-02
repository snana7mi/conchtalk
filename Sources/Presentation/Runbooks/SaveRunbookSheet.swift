/// 文件说明：SaveRunbookSheet，把当前成功对话保存为操作手册。
import SwiftUI

/// SaveRunbookSheet：
/// 预填从对话抽出的名称。对话尚未成功结束时说明原因，并禁止保存。
struct SaveRunbookSheet: View {
    var model: RunbookListModel
    let messages: [Message]
    let sourceServerID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var displayName: String
    @State private var blockedReason: String?

    init(model: RunbookListModel, messages: [Message], sourceServerID: UUID) {
        self.model = model
        self.messages = messages
        self.sourceServerID = sourceServerID
        switch RunbookExtractor.extract(messages: messages) {
        case .success(let draft):
            _displayName = State(initialValue: draft.suggestedDisplayName)
            _blockedReason = State(initialValue: nil)
        case .failure(.noUserRequest):
            _displayName = State(initialValue: "")
            _blockedReason = State(initialValue: String(localized: "A runbook needs at least one user request.", bundle: LanguageSettings.currentBundle))
        case .failure(.notSuccessful):
            _displayName = State(initialValue: "")
            _blockedReason = State(initialValue: String(localized: "This conversation cannot be saved yet. Wait until the assistant finishes successfully.", bundle: LanguageSettings.currentBundle))
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                if let blockedReason {
                    Section {
                        Text(blockedReason)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section {
                        TextField(
                            String(localized: "Runbook name", bundle: LanguageSettings.currentBundle),
                            text: $displayName
                        )
                        #if os(iOS)
                        .textInputAutocapitalization(.sentences)
                        #endif
                    } footer: {
                        Text(String(localized: "Saved runbooks become skills the assistant can activate.", bundle: LanguageSettings.currentBundle))
                    }
                }
                if let errorMessage = model.errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(String(localized: "Save as Runbook", bundle: LanguageSettings.currentBundle))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel", bundle: LanguageSettings.currentBundle)) {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Save", bundle: LanguageSettings.currentBundle)) {
                        if model.save(displayName: displayName, messages: messages, sourceServerID: sourceServerID) {
                            dismiss()
                        }
                    }
                    .disabled(blockedReason != nil || displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }
}
