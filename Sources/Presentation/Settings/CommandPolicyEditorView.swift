/// 文件说明：CommandPolicyEditorView，编辑某台服务器的允许/拒绝命令，并撤销「始终允许」规则。
import SwiftUI

/// CommandPolicyEditorViewModel：
/// 允许/拒绝列表走 CommandPolicyStore；「始终允许」继续复用 ApprovalRule 的读和删。
@MainActor
@Observable
final class CommandPolicyEditorViewModel {
    private let policyStore: ApprovalPolicyStore
    private let serverID: UUID
    private(set) var policy = ServerCommandPolicy.empty
    private(set) var rules: [ApprovalRule] = []
    var allowDraft = ""
    var denyDraft = ""
    var editError: CommandPolicyEditError?

    init(policyStore: ApprovalPolicyStore, serverID: UUID) {
        self.policyStore = policyStore
        self.serverID = serverID
    }

    func load() async {
        policy = await policyStore.commandPolicy(for: serverID)
        rules = await policyStore.allRules(forServer: serverID)
    }

    func addAllow() async {
        await insert(draft: allowDraft, into: .allow)
    }

    func addDeny() async {
        await insert(draft: denyDraft, into: .deny)
    }

    func removeAllow(_ entry: String) async {
        policy.allow.removeAll { $0 == entry }
        await persist()
    }

    func removeDeny(_ entry: String) async {
        policy.deny.removeAll { $0 == entry }
        await persist()
    }

    func deleteRule(_ rule: ApprovalRule) async {
        await policyStore.delete(ruleID: rule.id)
        rules.removeAll { $0.id == rule.id }
    }

    private func insert(draft: String, into list: CommandPolicyList) async {
        switch policy.inserting(draft, into: list) {
        case .failure(let error):
            editError = error
        case .success(let updated):
            let previous = policy
            policy = updated
            switch list {
            case .allow: allowDraft = ""
            case .deny: denyDraft = ""
            }
            editError = nil
            let saved = await policyStore.saveCommandPolicy(policy, forServer: serverID)
            if !saved {
                policy = previous
                editError = .saveFailed
            }
        }
    }

    private func persist() async {
        let saved = await policyStore.saveCommandPolicy(policy, forServer: serverID)
        if !saved {
            editError = .saveFailed
            await load()
        }
    }
}

/// CommandPolicyEditorView：一台服务器的命令策略。拒绝压过允许；禁止命令不能加入允许列表。
struct CommandPolicyEditorView: View {
    @State var viewModel: CommandPolicyEditorViewModel

    var body: some View {
        Form {
            Section {
                Text(String(
                    localized: "Deny rules override allow rules and always-allow rules. Forbidden commands cannot be added to the allow list.",
                    bundle: LanguageSettings.currentBundle
                ))
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            commandSection(
                title: String(localized: "Deny List", bundle: LanguageSettings.currentBundle),
                entries: viewModel.policy.deny,
                draft: $viewModel.denyDraft,
                add: { Task { await viewModel.addDeny() } },
                remove: { entry in Task { await viewModel.removeDeny(entry) } }
            )
            commandSection(
                title: String(localized: "Allow List", bundle: LanguageSettings.currentBundle),
                entries: viewModel.policy.allow,
                draft: $viewModel.allowDraft,
                add: { Task { await viewModel.addAllow() } },
                remove: { entry in Task { await viewModel.removeAllow(entry) } }
            )

            Section {
                if viewModel.rules.isEmpty {
                    Text(String(localized: "No Trusted Actions", bundle: LanguageSettings.currentBundle))
                        .foregroundStyle(.secondary)
                }
                ForEach(viewModel.rules) { rule in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(rule.displayLabel)
                            .font(.body)
                        Text(rule.toolName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            Task { await viewModel.deleteRule(rule) }
                        } label: {
                            Label(String(localized: "Revoke", bundle: LanguageSettings.currentBundle), systemImage: "trash")
                        }
                    }
                }
            } header: {
                Text(String(localized: "Always Allow", bundle: LanguageSettings.currentBundle))
            } footer: {
                Text(String(
                    localized: "Trusted actions are stored on this device.",
                    bundle: LanguageSettings.currentBundle
                ))
            }
        }
        .navigationTitle(String(localized: "Command Policy", bundle: LanguageSettings.currentBundle))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await viewModel.load() }
        .alert(
            String(localized: "Command Policy", bundle: LanguageSettings.currentBundle),
            isPresented: Binding(
                get: { viewModel.editError != nil },
                set: { if !$0 { viewModel.editError = nil } }
            )
        ) {
            Button(String(localized: "OK", bundle: LanguageSettings.currentBundle)) {
                viewModel.editError = nil
            }
        } message: {
            Text(message(for: viewModel.editError))
        }
    }

    private func commandSection(
        title: String,
        entries: [String],
        draft: Binding<String>,
        add: @escaping () -> Void,
        remove: @escaping (String) -> Void
    ) -> some View {
        Section {
            if entries.isEmpty {
                Text(String(localized: "No commands in this list.", bundle: LanguageSettings.currentBundle))
                    .foregroundStyle(.secondary)
            }
            ForEach(entries, id: \.self) { entry in
                Text(entry)
                    .font(.system(.body, design: .monospaced))
                    .swipeActions {
                        Button(role: .destructive) { remove(entry) } label: {
                            Label(String(localized: "Delete", bundle: LanguageSettings.currentBundle), systemImage: "trash")
                        }
                    }
            }
            HStack {
                TextField(String(localized: "Command Pattern", bundle: LanguageSettings.currentBundle), text: draft)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #endif
                    .onSubmit(add)
                Button(String(localized: "Add", bundle: LanguageSettings.currentBundle), action: add)
                    .disabled(draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        } header: {
            Text(title)
        } footer: {
            Text(String(
                localized: "An entry matches a command segment that starts with the same words. The deny list blocks a match even when the command would otherwise run automatically.",
                bundle: LanguageSettings.currentBundle
            ))
        }
    }

    private func message(for error: CommandPolicyEditError?) -> String {
        switch error {
        case .empty:
            String(localized: "Enter a command.", bundle: LanguageSettings.currentBundle)
        case .duplicate:
            String(localized: "That command is already in the list.", bundle: LanguageSettings.currentBundle)
        case .forbiddenAllow:
            String(
                localized: "This command is forbidden and cannot be added to the allow list.",
                bundle: LanguageSettings.currentBundle
            )
        case .saveFailed:
            String(localized: "Could not save the command policy.", bundle: LanguageSettings.currentBundle)
        case nil:
            ""
        }
    }
}
