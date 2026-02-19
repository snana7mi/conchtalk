/// 文件说明：ManageGroupsView，负责服务器列表与分组管理界面。
import SwiftUI

/// ManageGroupsView：负责界面渲染与用户交互响应。
struct ManageGroupsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var newGroupName = ""

    let groups: [ServerGroup]
    let onAdd: (String) async -> Void
    let onDelete: (UUID) async -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField("Group Name", text: $newGroupName)
                        Button("Add") {
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
                    Text("Add Group")
                }

                Section {
                    if groups.isEmpty {
                        Text("No groups yet")
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
                    Text("Groups")
                }
            }
            .navigationTitle("Manage Groups")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
