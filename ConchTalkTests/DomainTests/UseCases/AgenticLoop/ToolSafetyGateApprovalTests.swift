/// 文件说明：ToolSafetyGateApprovalTests，验证门的规则自动放行与四态结果分派。
import Testing
import Foundation
@testable import ConchTalk

@Suite("ToolSafetyGateApproval")
struct ToolSafetyGateApprovalTests {
    private final class FakePolicy: ApprovalPolicyProviding, @unchecked Sendable {
        var auto = false
        var suggested: ApprovalRule? = nil
        private(set) var saved: [ApprovalRule] = []
        private(set) var sessionMatchers: [ApprovalMatcher] = []
        func autoApproves(serverID: UUID, toolName: String, arguments: [String: Any], permissionLevel: PermissionLevel) async -> Bool { auto }
        func suggestRule(serverID: UUID, toolName: String, arguments: [String: Any], permissionLevel: PermissionLevel) async -> ApprovalRule? { suggested }
        func save(_ rule: ApprovalRule) async { saved.append(rule) }
        func trustForSession(serverID: UUID, matcher: ApprovalMatcher) async { sessionMatchers.append(matcher) }
        func clearSessionTrust(serverID: UUID) async {}
    }
    private struct FakePreview: ApprovalPreviewProviding {
        func buildPreview(toolName: String, arguments: [String: Any], sshClient: SSHClientProtocol) async -> ApprovalPreview { .command(text: "x") }
    }

    /// 复用既有 MockSSHClient：默认 sftpWriteFile 成功（无 error）、sftpFileSize 返回 0，
    /// 使 WriteFileTool.execute 顺利完成，让 .executed 判定不受执行失败干扰。
    private func makeSSHClient() -> MockSSHClient {
        let client = MockSSHClient()
        client.sftpFileSizeResult = 1
        return client
    }

    private func runGate(policy: FakePolicy, onConfirm: @escaping @Sendable (ConfirmationRequest) async -> CommandApproval) async -> ToolGateResult {
        let tool = WriteFileTool() // validateSafety == .needsConfirmation
        let args: [String: Any] = ["path": "/a", "content": "x", "explanation": "t"]
        let call = ToolCall(id: "1", toolName: "write_file",
                            argumentsJSON: try! JSONSerialization.data(withJSONObject: args), explanation: "t")
        return await ToolSafetyGate.evaluate(
            toolCall: call, tool: tool, arguments: args, sshClient: makeSSHClient(),
            permissionLevel: .standard, serverID: UUID(),
            policyStore: policy, previewBuilder: FakePreview(),
            onConfirmation: onConfirm, onOutput: { _ in }, onAgentEvents: { _ in })
    }

    @Test("命中规则则不弹窗直接执行")
    func autoApprove() async {
        let policy = FakePolicy(); policy.auto = true
        let prompted = LockedBox(false)
        let r = await runGate(policy: policy) { _ in prompted.set(true); return .denied }
        #expect(prompted.value == false)
        if case .executed = r {} else { Issue.record("应执行") }
    }

    @Test("approvedAlways 会持久化规则")
    func always() async {
        let policy = FakePolicy()
        let rule = ApprovalRule(id: UUID(), serverID: UUID(), toolName: "write_file",
            matcher: .pathPrefix(prefix: "/a", recursive: false), displayLabel: "/a",
            createdAt: Date(), modifiedAt: Date())
        _ = await runGate(policy: policy) { _ in .approvedAlways(rule) }
        #expect(policy.saved.count == 1)
    }

    @Test("denied 不执行")
    func denied() async {
        let r = await runGate(policy: FakePolicy()) { _ in .denied }
        if case .denied = r {} else { Issue.record("应 denied") }
    }
}
