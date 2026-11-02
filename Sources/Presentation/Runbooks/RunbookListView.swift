/// 文件说明：RunbookListView，展示已保存的操作手册并在选定服务器上再次运行。
import SwiftUI

/// RunbookListView：
/// 列表里的每一本手册都可以选一台服务器重跑。当前聊天服务器会作为默认目标。
struct RunbookListView: View {
    @State var model: RunbookListModel
    var currentServer: Server? = nil
    var servers: [Server] = []
    var onRun: (Server, String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if model.runbooks.isEmpty {
                    ContentUnavailableView {
                        Label(String(localized: "No runbooks yet", bundle: LanguageSettings.currentBundle), systemImage: "text.book.closed")
                    } description: {
                        Text(String(localized: "Save a finished conversation, then run it again on any server.", bundle: LanguageSettings.currentBundle))
                    }
                } else {
                    List {
                        Section {
                            Text(String(localized: "Saved runbooks become skills the assistant can activate.", bundle: LanguageSettings.currentBundle))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(model.runbooks) { runbook in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(runbook.displayName)
                                    .font(.body.weight(.semibold))
                                Text(runbook.name)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                runButtons(for: runbook)
                            }
                            .padding(.vertical, 4)
                            .swipeActions {
                                Button(role: .destructive) {
                                    model.delete(runbook)
                                } label: {
                                    Label(String(localized: "Delete", bundle: LanguageSettings.currentBundle), systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(String(localized: "Runbooks", bundle: LanguageSettings.currentBundle))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel", bundle: LanguageSettings.currentBundle)) {
                        dismiss()
                    }
                }
            }
            .alert(
                String(localized: "Runbooks", bundle: LanguageSettings.currentBundle),
                isPresented: Binding(
                    get: { model.errorMessage != nil },
                    set: { if !$0 { model.errorMessage = nil } }
                )
            ) {
                Button(String(localized: "OK", bundle: LanguageSettings.currentBundle), role: .cancel) {}
            } message: {
                Text(model.errorMessage ?? "")
            }
        }
        .task { model.reload() }
    }

    @ViewBuilder
    private func runButtons(for runbook: Runbook) -> some View {
        if let currentServer {
            Button(String(localized: "Run on this server", bundle: LanguageSettings.currentBundle)) {
                run(runbook, on: currentServer)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        } else if servers.isEmpty {
            Text(String(localized: "No Servers", bundle: LanguageSettings.currentBundle))
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Menu(String(localized: "Run", bundle: LanguageSettings.currentBundle)) {
                ForEach(servers) { server in
                    Button(server.name) {
                        run(runbook, on: server)
                    }
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private func run(_ runbook: Runbook, on server: Server) {
        onRun(server, RunbookSkillRenderer.replayPrompt(for: runbook))
        dismiss()
    }
}
