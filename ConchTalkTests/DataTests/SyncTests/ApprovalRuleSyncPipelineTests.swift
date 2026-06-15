/// 文件说明：ApprovalRuleSyncPipelineTests，验证授权规则经 merge engine 的端到端合并。
import Testing
import SwiftData
import Foundation
@testable import ConchTalk

@Suite("ApprovalRuleSyncPipeline")
struct ApprovalRuleSyncPipelineTests {
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

    @Test("merge engine 能解码并合并 approvalRule")
    func mergeViaEngine() async throws {
        let store = try makeStore()
        let engine = SyncMergeEngine(store: store, keychainService: MockKeychainService())
        let sid = UUID(); let id = UUID()
        let remote = SwiftDataStore.SyncableApprovalRule(
            id: id, serverID: sid, toolName: "write_file", matcherKind: "pathPrefix",
            tokensJSON: nil, pathPrefix: "/srv", recursive: true, displayLabel: "x",
            createdAt: Date(), syncVersion: 5, modifiedAt: Date(), isDeleted: false, isRemoteMerge: false)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let (merged, _) = try await engine.merge(entityType: .approvalRule, jsonData: try encoder.encode(remote))
        #expect(merged == 1)
        #expect(try await store.fetchApprovalRules(forServer: sid).count == 1)
    }
}
