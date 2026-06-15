/// 文件说明：ApprovalRuleSyncStoreTests，验证授权规则的变更收集与远端 LWW 合并。
import Testing
import SwiftData
import Foundation
@testable import ConchTalk

@Suite("ApprovalRuleSyncStore")
struct ApprovalRuleSyncStoreTests {
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

    @Test("本地保存后能被 fetchChanged 收集")
    func collectChanged() async throws {
        let store = try makeStore(); let sid = UUID()
        try await store.saveApprovalRule(ApprovalRule(id: UUID(), serverID: sid, toolName: "write_file",
            matcher: .pathPrefix(prefix: "/srv", recursive: true), displayLabel: "x",
            createdAt: Date(), modifiedAt: Date()))
        let changed = try await store.fetchChangedApprovalRules(since: 0, limit: 50)
        #expect(changed.count == 1)
    }

    @Test("远端较新者胜出（LWW）")
    func mergeRemoteWins() async throws {
        let store = try makeStore(); let sid = UUID(); let id = UUID()
        try await store.saveApprovalRule(ApprovalRule(id: id, serverID: sid, toolName: "write_file",
            matcher: .pathPrefix(prefix: "/old", recursive: false), displayLabel: "old",
            createdAt: Date(), modifiedAt: Date(timeIntervalSince1970: 1000)))
        // 本地 saveApprovalRule 会把 modifiedAt 覆写为 Date()（与 MemoryEntry 一致），
        // 故远端须用未来时间戳才比本地新，以触发 LWW 远端胜出。
        let remote = SwiftDataStore.SyncableApprovalRule(
            id: id, serverID: sid, toolName: "write_file", matcherKind: "pathPrefix",
            tokensJSON: nil, pathPrefix: "/new", recursive: true, displayLabel: "new",
            createdAt: Date(), syncVersion: 999, modifiedAt: Date().addingTimeInterval(3600),
            isDeleted: false, isRemoteMerge: false)
        let (merged, _) = try await store.mergeRemoteApprovalRule(remote)
        #expect(merged == 1)
        let rules = try await store.fetchApprovalRules(forServer: sid)
        #expect(rules.first?.displayLabel == "new")
    }
}
