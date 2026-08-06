/// 文件说明：ApprovalRuleStoreTests，验证授权规则的持久化 CRUD 与软删除。
import Testing
import SwiftData
import Foundation
@testable import ConchTalk

@Suite("ApprovalRuleStore")
struct ApprovalRuleStoreTests {
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

    private func sampleRule(server: UUID) -> ApprovalRule {
        ApprovalRule(id: UUID(), serverID: server, toolName: "write_file",
                     matcher: .pathPrefix(prefix: "/srv", recursive: true),
                     displayLabel: "写入 /srv 下", createdAt: Date(), modifiedAt: Date())
    }

    @Test("保存后可按服务器读取")
    func saveAndFetch() async throws {
        let store = try makeStore(); let sid = UUID()
        try await store.saveApprovalRule(sampleRule(server: sid))
        let rules = try await store.fetchApprovalRules(forServer: sid)
        #expect(rules.count == 1)
        #expect(rules[0].toolName == "write_file")
    }

    @Test("按服务器隔离")
    func isolation() async throws {
        let store = try makeStore(); let a = UUID(); let b = UUID()
        try await store.saveApprovalRule(sampleRule(server: a))
        #expect(try await store.fetchApprovalRules(forServer: b).isEmpty)
    }

    @Test("软删除后读不到")
    func softDelete() async throws {
        let store = try makeStore(); let sid = UUID()
        let r = sampleRule(server: sid)
        try await store.saveApprovalRule(r)
        try await store.deleteApprovalRule(r.id)
        #expect(try await store.fetchApprovalRules(forServer: sid).isEmpty)
    }

    @Test("重复保存同 id 幂等")
    func idempotent() async throws {
        let store = try makeStore(); let sid = UUID()
        let r = sampleRule(server: sid)
        try await store.saveApprovalRule(r)
        try await store.saveApprovalRule(r)
        #expect(try await store.fetchApprovalRules(forServer: sid).count == 1)
    }
}
