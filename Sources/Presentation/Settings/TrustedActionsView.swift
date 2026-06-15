/// 文件说明：TrustedActionsView，按服务器列出已保存的「始终允许」规则，可删除（撤销）。
import SwiftUI

/// TrustedActionsViewModel：
/// 通过 ApprovalPolicyStore 读取/撤销某服务器的「始终允许」授权规则。
@MainActor @Observable
final class TrustedActionsViewModel {
    private let policyStore: ApprovalPolicyStore
    private let serverID: UUID
    var rules: [ApprovalRule] = []

    init(policyStore: ApprovalPolicyStore, serverID: UUID) {
        self.policyStore = policyStore
        self.serverID = serverID
    }

    /// 加载当前服务器的全部规则。
    func load() async {
        rules = await policyStore.allRules(forServer: serverID)
    }

    /// 撤销一条规则并刷新列表。
    func delete(_ rule: ApprovalRule) async {
        await policyStore.delete(ruleID: rule.id)
        await load()
    }
}

/// TrustedActionsView：
/// 列出某服务器已记忆的「始终允许」规则，支持滑动撤销；空态给出引导提示。
struct TrustedActionsView: View {
    @State var viewModel: TrustedActionsViewModel

    var body: some View {
        List {
            if viewModel.rules.isEmpty {
                ContentUnavailableView(
                    String(localized: "No Trusted Actions", bundle: LanguageSettings.currentBundle),
                    systemImage: "checkmark.shield"
                )
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
                        Task { await viewModel.delete(rule) }
                    } label: {
                        Label(
                            String(localized: "Revoke", bundle: LanguageSettings.currentBundle),
                            systemImage: "trash"
                        )
                    }
                }
            }
            Section {
                Text(String(localized: "Trusted actions sync across your devices.", bundle: LanguageSettings.currentBundle))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(String(localized: "Trusted Actions", bundle: LanguageSettings.currentBundle))
        .task { await viewModel.load() }
    }
}
