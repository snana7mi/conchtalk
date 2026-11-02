/// 文件说明：ServerBatchSheet，对一个服务器分组填写同一任务并查看对比结果。
import SwiftUI

/// ServerBatchSheet：
/// 展示分组里的服务器数量。运行时沿用 subagent 的并发上限，每台服务器仍单独审批。
struct ServerBatchSheet: View {
    let groupName: String
    let serverCount: Int
    let run: (String) async -> ServerBatchReport
    @Environment(\.dismiss) private var dismiss
    @State private var prompt = ""
    @State private var isRunning = false
    @State private var report: ServerBatchReport?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(String(
                        format: String(localized: "%d servers", bundle: LanguageSettings.currentBundle),
                        serverCount
                    ))
                    Text(String(localized: "The same task runs on each server in parallel. Approval is still requested separately on every server.", bundle: LanguageSettings.currentBundle))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section(String(localized: "Batch task", bundle: LanguageSettings.currentBundle)) {
                    TextField(
                        String(localized: "What should each server do?", bundle: LanguageSettings.currentBundle),
                        text: $prompt,
                        axis: .vertical
                    )
                    .lineLimit(3...8)
                }
                if isRunning {
                    Section {
                        ProgressView()
                    }
                }
                if let report {
                    Section(String(localized: "Comparison", bundle: LanguageSettings.currentBundle)) {
                        Text(report.markdown)
                            .font(.callout)
                            .textSelection(.enabled)
                        ForEach(report.results) { result in
                            LabeledContent(result.serverName) {
                                Text(result.succeeded
                                     ? String(localized: "OK", bundle: LanguageSettings.currentBundle)
                                     : String(localized: "Failed", bundle: LanguageSettings.currentBundle))
                            }
                        }
                    }
                }
            }
            .navigationTitle(groupName)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel", bundle: LanguageSettings.currentBundle)) {
                        dismiss()
                    }
                    .disabled(isRunning)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Run on group", bundle: LanguageSettings.currentBundle)) {
                        Task { await start() }
                    }
                    .disabled(isRunning || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || serverCount == 0)
                }
            }
        }
    }

    private func start() async {
        isRunning = true
        report = await run(prompt)
        isRunning = false
    }
}
