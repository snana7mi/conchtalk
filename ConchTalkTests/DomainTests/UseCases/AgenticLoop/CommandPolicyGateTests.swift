/// 文件说明：CommandPolicyGateTests，验证安全门执行命令词表：拒绝拦截，允许跳过确认。
import Foundation
import Testing
@testable import ConchTalk

@Suite("CommandPolicyGate")
struct CommandPolicyGateTests {
    nonisolated private final class Policy: ApprovalPolicyProviding, @unchecked Sendable {
        var policy = ServerCommandPolicy.empty
        func commandPolicy(for serverID: UUID) async -> ServerCommandPolicy { policy }
        func autoApproves(serverID: UUID, toolName: String, arguments: [String: Any], permissionLevel: PermissionLevel) async -> Bool { false }
        func suggestRule(serverID: UUID, toolName: String, arguments: [String: Any], permissionLevel: PermissionLevel) async -> ApprovalRule? { nil }
        func save(_ rule: ApprovalRule) async {}
        func trustForSession(serverID: UUID, matcher: ApprovalMatcher) async {}
        func clearSessionTrust(serverID: UUID) async {}
    }

    private func evaluate(
        command: String,
        rawSafety: SafetyLevel,
        policy: ServerCommandPolicy,
        permission: PermissionLevel = .standard,
        background: Bool = false,
        onConfirm: @escaping @Sendable (ConfirmationRequest) async -> CommandApproval = { _ in .denied }
    ) async -> (ToolGateResult, MockTool) {
        let tool = MockTool(name: "execute_ssh_command", safetyLevel: rawSafety, executeResult: ToolExecutionResult(output: "ok"))
        let ssh = MockSSHClient()
        ssh.executeResult = "ok"
        let gatePolicy = Policy()
        gatePolicy.policy = policy
        var args: [String: Any] = ["command": command, "explanation": "t", "is_destructive": true]
        if background {
            args["background"] = true
        }
        let call = ToolCall(
            id: "1",
            toolName: "execute_ssh_command",
            argumentsJSON: try! JSONSerialization.data(withJSONObject: args),
            explanation: "t"
        )
        let result = await ToolSafetyGate.evaluate(
            toolCall: call,
            tool: tool,
            arguments: args,
            sshClient: ssh,
            permissionLevel: permission,
            serverID: UUID(),
            policyStore: gatePolicy,
            onConfirmation: onConfirm,
            onOutput: { _ in },
            onAgentEvents: { _ in }
        )
        return (result, tool)
    }

    @Test("拒绝列表拦截本来会自动执行的命令")
    func denyBlocksSafeCommand() async {
        let (result, tool) = await evaluate(command: "ls", rawSafety: .safe, policy: ServerCommandPolicy(deny: ["ls"]))
        if case .forbidden = result {} else { Issue.record("应禁止") }
        #expect(tool.executeCalled == 0)
    }

    @Test("允许列表让非禁止命令跳过确认")
    func allowSkipsConfirmation() async {
        let prompted = LockedBox(false)
        let (result, tool) = await evaluate(
            command: "systemctl restart nginx",
            rawSafety: .needsConfirmation,
            policy: ServerCommandPolicy(allow: ["systemctl restart nginx"]),
            onConfirm: { _ in prompted.set(true); return .denied }
        )
        #expect(prompted.value == false)
        if case .executed(let output, let hadWrite) = result {
            #expect(output.output == "ok")
            #expect(hadWrite == true)
        } else {
            Issue.record("应直接执行")
        }
        #expect(tool.executeCalled == 1)
    }

    @Test("允许列表不能让禁止命令执行")
    func allowDoesNotRunForbidden() async {
        let (result, tool) = await evaluate(
            command: "rm -rf /",
            rawSafety: .safe,
            policy: ServerCommandPolicy(allow: ["rm -rf /"])
        )
        if case .forbidden = result {} else { Issue.record("应禁止") }
        #expect(tool.executeCalled == 0)
    }

    @Test("允许列表不能跳过后台命令的确认")
    func allowDoesNotSkipBackgroundConfirmation() async {
        let (result, tool) = await evaluate(
            command: "ls",
            rawSafety: .needsConfirmation,
            policy: ServerCommandPolicy(allow: ["ls"]),
            background: true,
            onConfirm: { _ in .denied }
        )
        if case .denied = result {} else { Issue.record("应等待确认并被拒绝") }
        #expect(tool.executeCalled == 0)
    }

    @Test("strict 下允许列表仍要确认")
    func strictStillConfirmsAllow() async {
        let (result, tool) = await evaluate(
            command: "systemctl restart nginx",
            rawSafety: .needsConfirmation,
            policy: ServerCommandPolicy(allow: ["systemctl restart nginx"]),
            permission: .strict,
            onConfirm: { _ in .denied }
        )
        if case .denied = result {} else { Issue.record("应等待确认并被拒绝") }
        #expect(tool.executeCalled == 0)
    }
}
