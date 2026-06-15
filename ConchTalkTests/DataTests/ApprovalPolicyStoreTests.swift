/// 文件说明：ApprovalPolicyStoreTests，验证自动放行的 strict/会话/持久化/hardening 行为。
import Testing
import SwiftData
import Foundation
@testable import ConchTalk

@Suite("ApprovalPolicyStore")
struct ApprovalPolicyStoreTests {
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

    @Test("无规则不放行")
    func noRule() async throws {
        let policy = ApprovalPolicyStore(store: try makeStore())
        let ok = await policy.autoApproves(serverID: UUID(), toolName: "execute_ssh_command",
            arguments: ["command": "git -C /srv/app pull"], permissionLevel: .standard)
        #expect(ok == false)
    }

    @Test("持久化 always 规则命中放行")
    func persistedRule() async throws {
        let store = try makeStore(); let sid = UUID()
        let policy = ApprovalPolicyStore(store: store)
        try await store.saveApprovalRule(ApprovalRule(id: UUID(), serverID: sid, toolName: "execute_ssh_command",
            matcher: .commandPrefix(tokens: ["git", "-C", "/srv/app", "pull"]), displayLabel: "git pull",
            createdAt: Date(), modifiedAt: Date()))
        let ok = await policy.autoApproves(serverID: sid, toolName: "execute_ssh_command",
            arguments: ["command": "git -C /srv/app pull --rebase"], permissionLevel: .standard)
        #expect(ok == true)
    }

    @Test("strict 模式忽略规则")
    func strictIgnores() async throws {
        let store = try makeStore(); let sid = UUID()
        let policy = ApprovalPolicyStore(store: store)
        try await store.saveApprovalRule(ApprovalRule(id: UUID(), serverID: sid, toolName: "execute_ssh_command",
            matcher: .commandPrefix(tokens: ["ls"]), displayLabel: "ls", createdAt: Date(), modifiedAt: Date()))
        let ok = await policy.autoApproves(serverID: sid, toolName: "execute_ssh_command",
            arguments: ["command": "ls -la"], permissionLevel: .strict)
        #expect(ok == false)
    }

    @Test("hardening 命中即使有规则也不放行")
    func hardeningVeto() async throws {
        let store = try makeStore(); let sid = UUID()
        let policy = ApprovalPolicyStore(store: store)
        try await store.saveApprovalRule(ApprovalRule(id: UUID(), serverID: sid, toolName: "execute_ssh_command",
            matcher: .commandPrefix(tokens: ["git", "-C", "/srv/app", "pull"]), displayLabel: "x",
            createdAt: Date(), modifiedAt: Date()))
        let ok = await policy.autoApproves(serverID: sid, toolName: "execute_ssh_command",
            arguments: ["command": "git -C /srv/app pull > /etc/passwd"], permissionLevel: .standard)
        #expect(ok == false)
    }

    @Test("session 信任命中 + 清空后失效")
    func sessionTrust() async throws {
        let sid = UUID()
        let policy = ApprovalPolicyStore(store: try makeStore())
        await policy.trustForSession(serverID: sid, matcher: .commandPrefix(tokens: ["systemctl", "status"]))
        var ok = await policy.autoApproves(serverID: sid, toolName: "execute_ssh_command",
            arguments: ["command": "systemctl status nginx"], permissionLevel: .standard)
        #expect(ok == true)
        await policy.clearSessionTrust(serverID: sid)
        ok = await policy.autoApproves(serverID: sid, toolName: "execute_ssh_command",
            arguments: ["command": "systemctl status nginx"], permissionLevel: .standard)
        #expect(ok == false)
    }

    @Test("suggestRule：standard 给规则，strict 给 nil")
    func suggest() async throws {
        let policy = ApprovalPolicyStore(store: try makeStore()); let sid = UUID()
        let r = await policy.suggestRule(serverID: sid, toolName: "write_file",
            arguments: ["path": "/srv/a.conf"], permissionLevel: .standard)
        #expect(r?.matcher == .pathPrefix(prefix: "/srv/a.conf", recursive: false))
        let none = await policy.suggestRule(serverID: sid, toolName: "write_file",
            arguments: ["path": "/srv/a.conf"], permissionLevel: .strict)
        #expect(none == nil)
    }
}
