/// 文件说明：ApprovalFlowIntegrationTests，在真实测试服上验证审批预览与分级授权策略的端到端行为。
@testable import ConchTalk
import Foundation
import SwiftData
import Testing

/// ApprovalFlowIntegrationTests：
/// 针对真实 SSH 连接验证三件事：
/// (a) write_file 覆盖既有临时文件 → ApprovalPreviewBuilder.buildPreview 返回 .fileDiff 且 diff 行正确；
/// (b) 保存 commandPrefix(["systemctl","status"]) always 规则 → autoApproves("systemctl status sshd") == true；
/// (c) autoApproves("systemctl status sshd > /tmp/x") == false（hardening 在真机命令串上否决）。
/// 连接信息来自 IntegrationTestConfig（JSON 文件或 CT_TEST_* 环境变量），不写入源码；
/// 无凭据时整套 suite 在 discovery 阶段被 .enabled(if:) 禁用而跳过，不会失败。
@Suite(.tags(.integration), .serialized, .enabled(if: IntegrationTestConfig.isAvailable))
struct ApprovalFlowIntegrationTests {

    // MARK: - Helpers

    /// 生成唯一的临时文件路径，避免测试间冲突。
    private func testFilePath() -> String {
        "/tmp/conchtalk-approval-\(UUID().uuidString)"
    }

    /// 构建仅含内存存储的 SwiftDataStore（不触网），用于授权规则的持久化。
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

    // MARK: - (a) write_file 覆盖预览

    /// 真实连接：先建立基线临时文件，再以 write_file 覆盖 → 预览为 .fileDiff 且 diff 行正确。
    @Test
    func writeFileOverwriteProducesFileDiff() async throws {
        let config = try #require(IntegrationTestConfig.load())
        let client = try await config.connectSSH()
        defer { Task { await client.disconnect() } }

        let path = testFilePath()
        defer { Task { _ = try? await client.execute(command: "rm -f \(path)") } }

        // 基线内容：三行；通过 SSH 直接写入，确保远端文件存在且内容确定。
        let delimiter = "CONCHTALK_BASE_\(UUID().uuidString.prefix(8))"
        _ = try await client.execute(command: "cat <<'\(delimiter)' > \(path)\nalpha\nbeta\ngamma\n\(delimiter)")
        let check = try await client.execute(command: "test -f \(path) && echo OK || echo MISSING")
        #expect(check.trimmingCharacters(in: .whitespacesAndNewlines) == "OK")

        // 覆盖内容：保留首尾、替换中间行；buildPreview 只读远端、不执行写入。
        let newContent = "alpha\nDELTA\ngamma\n"
        let builder = ApprovalPreviewBuilder()
        let preview = await builder.buildPreview(
            toolName: "write_file",
            arguments: ["path": path, "content": newContent],
            sshClient: client
        )

        guard case let .fileDiff(lines, summary) = preview else {
            Issue.record("期望 .fileDiff，实际为 \(preview)")
            return
        }

        // 远端基线 = ["alpha","beta","gamma",""]，新内容 = ["alpha","DELTA","gamma",""]
        // → beta 删除、DELTA 新增，alpha/gamma/尾空行为上下文。
        #expect(lines.contains(.context("alpha")))
        #expect(lines.contains(.removed("beta")))
        #expect(lines.contains(.added("DELTA")))
        #expect(lines.contains(.context("gamma")))
        let added = lines.filter { if case .added = $0 { true } else { false } }.count
        let removed = lines.filter { if case .removed = $0 { true } else { false } }.count
        #expect(added == 1)
        #expect(removed == 1)
        #expect(summary == "+1 −1")

        // 预览是只读的：远端文件内容未被改写，仍为基线。
        let after = try await client.execute(command: "cat \(path)")
        #expect(after.contains("beta"))
        #expect(!after.contains("DELTA"))
    }

    // MARK: - (b)(c) 分级授权策略（真机命令串）

    /// 保存 commandPrefix(["systemctl","status"]) always 规则后，对真实服务器命令串验证 autoApproves。
    @Test
    func systemctlStatusAlwaysRuleAutoApproves() async throws {
        let config = try #require(IntegrationTestConfig.load())
        let client = try await config.connectSSH()
        defer { Task { await client.disconnect() } }

        // 先在真机上确认该命令本身可执行（验证命令串是活的，而非凭空构造）。
        _ = try await client.execute(command: "systemctl status sshd || true")

        let store = try makeStore()
        let policy = ApprovalPolicyStore(store: store)
        let serverID = UUID()

        try await store.saveApprovalRule(ApprovalRule(
            id: UUID(),
            serverID: serverID,
            toolName: "execute_ssh_command",
            matcher: .commandPrefix(tokens: ["systemctl", "status"]),
            displayLabel: "systemctl status",
            createdAt: Date(),
            modifiedAt: Date()
        ))

        // (b) 规则命中：尾部多余参数仍命中。
        let approved = await policy.autoApproves(
            serverID: serverID,
            toolName: "execute_ssh_command",
            arguments: ["command": "systemctl status sshd"],
            permissionLevel: .standard
        )
        #expect(approved == true)

        // (c) hardening 否决：同一前缀但带输出重定向 → 绝不自动放行。
        let vetoed = await policy.autoApproves(
            serverID: serverID,
            toolName: "execute_ssh_command",
            arguments: ["command": "systemctl status sshd > /tmp/x"],
            permissionLevel: .standard
        )
        #expect(vetoed == false)
    }
}
