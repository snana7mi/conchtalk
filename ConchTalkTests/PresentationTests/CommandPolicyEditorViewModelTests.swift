/// 文件说明：CommandPolicyEditorViewModelTests，验证策略编辑器的允许/拒绝校验和规则撤销。
import Foundation
import SwiftData
import Testing
@testable import ConchTalk

@MainActor
@Suite("CommandPolicyEditor")
struct CommandPolicyEditorViewModelTests {
    @Test("禁止命令不能加入允许列表，拒绝项和始终允许规则可以删除")
    func editListsAndRevokeRule() async throws {
        let policies = CommandPolicyStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("editor-policy-\(UUID().uuidString).json"))
        let store = try makeStore()
        let policyStore = ApprovalPolicyStore(store: store, commandPolicies: policies)
        let serverID = UUID()
        let rule = ApprovalRule(
            id: UUID(), serverID: serverID, toolName: "execute_ssh_command",
            matcher: .commandPrefix(tokens: ["git", "status"]), displayLabel: "git status",
            createdAt: Date(), modifiedAt: Date()
        )
        try await store.saveApprovalRule(rule)

        let viewModel = CommandPolicyEditorViewModel(policyStore: policyStore, serverID: serverID)
        await viewModel.load()
        #expect(viewModel.rules.map(\.id) == [rule.id])

        viewModel.allowDraft = "rm -rf /"
        await viewModel.addAllow()
        #expect(viewModel.editError == .forbiddenAllow)
        #expect(viewModel.policy.allow.isEmpty)

        viewModel.allowDraft = "  "
        await viewModel.addAllow()
        #expect(viewModel.editError == .empty)

        viewModel.denyDraft = "ls"
        await viewModel.addDeny()
        #expect(viewModel.editError == nil)
        #expect(viewModel.policy.deny == ["ls"])
        viewModel.denyDraft = "ls"
        await viewModel.addDeny()
        #expect(viewModel.editError == .duplicate)

        viewModel.allowDraft = "systemctl restart nginx"
        await viewModel.addAllow()
        #expect(viewModel.policy.allow == ["systemctl restart nginx"])

        await viewModel.deleteRule(rule)
        #expect(viewModel.rules.isEmpty)
        #expect(try await store.fetchApprovalRules(forServer: serverID).isEmpty)

        let reloaded = CommandPolicyEditorViewModel(policyStore: policyStore, serverID: serverID)
        await reloaded.load()
        #expect(reloaded.policy.deny == ["ls"])
        #expect(reloaded.policy.allow == ["systemctl restart nginx"])
    }

    private func makeStore() throws -> SwiftDataStore {
        let schema = Schema([
            ServerModel.self,
            MessageModel.self,
            ServerGroupModel.self,
            SSHKeyModel.self,
            MemoryModel.self,
            MemoryEntryModel.self,
            SystemProfileModel.self,
            ApprovalRuleModel.self,
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        return SwiftDataStore(modelContainer: container)
    }
}
