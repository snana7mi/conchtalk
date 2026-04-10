/// 文件说明：ManageGroupsView，负责服务器列表与分组管理界面。
import SwiftUI

/// ManageGroupsView：负责界面渲染与用户交互响应。
struct ManageGroupsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var newGroupName = ""

    @Binding var groups: [ServerGroup]
    let onAdd: (String) async -> Void
    let onDelete: (UUID) async -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField(String(localized: "Group Name", bundle: LanguageSettings.currentBundle), text: $newGroupName)
                        Button(String(localized: "Add", bundle: LanguageSettings.currentBundle)) {
                            let name = newGroupName.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !name.isEmpty else { return }
                            Task {
                                await onAdd(name)
                                newGroupName = ""
                            }
                        }
                        .disabled(newGroupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                } header: {
                    Text(String(localized: "Add Group", bundle: LanguageSettings.currentBundle))
                }

                Section {
                    if groups.isEmpty {
                        Text(String(localized: "No groups yet", bundle: LanguageSettings.currentBundle))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(groups) { group in
                            Text(group.name)
                        }
                        .onDelete { indexSet in
                            for index in indexSet {
                                let group = groups[index]
                                Task { await onDelete(group.id) }
                            }
                        }
                    }
                } header: {
                    Text(String(localized: "Groups", bundle: LanguageSettings.currentBundle))
                }
            }
            .navigationTitle(String(localized: "Manage Groups", bundle: LanguageSettings.currentBundle))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done", bundle: LanguageSettings.currentBundle)) { dismiss() }
                }
            }
        }
    }
}
