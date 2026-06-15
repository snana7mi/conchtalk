/// 文件说明：ToolSafetyGateTests，验证安全分级与权限映射。
import Testing
@testable import ConchTalk

@Suite("ToolSafetyGate")
struct ToolSafetyGateTests {

    @Test("safe 工具直接执行")
    func safeAutoExecutes() async throws {
        let mockTool = MockTool()
        mockTool.safetyLevel = .safe
        mockTool.executeResult = ToolExecutionResult(output: "ok")
        let sshClient = MockSSHClient()

        let result = await ToolSafetyGate.evaluate(
            toolCall: TestFixtures.makeToolCall(toolName: "test"),
            tool: mockTool,
            arguments: [:],
            sshClient: sshClient,
            permissionLevel: .standard,
            onConfirmation: { _ in .denied },
            onOutput: { _ in },
            onAgentEvents: { _ in }
        )

        if case .executed(let r, let hadWrite) = result {
            #expect(r.output == "ok")
            #expect(hadWrite == false)
        } else {
            Issue.record("Expected .executed, got \(result)")
        }
    }

    @Test("needsConfirmation approved → hadWrite=true")
    func confirmedExecution() async throws {
        let mockTool = MockTool()
        mockTool.safetyLevel = .needsConfirmation
        mockTool.executeResult = ToolExecutionResult(output: "done")
        let sshClient = MockSSHClient()

        let result = await ToolSafetyGate.evaluate(
            toolCall: TestFixtures.makeToolCall(toolName: "write"),
            tool: mockTool,
            arguments: [:],
            sshClient: sshClient,
            permissionLevel: .standard,
            onConfirmation: { _ in .approvedOnce },
            onOutput: { _ in },
            onAgentEvents: { _ in }
        )

        if case .executed(let r, let hadWrite) = result {
            #expect(r.output == "done")
            #expect(hadWrite == true)
        } else {
            Issue.record("Expected .executed with hadWrite, got \(result)")
        }
    }

    @Test("needsConfirmation denied")
    func deniedExecution() async throws {
        let mockTool = MockTool()
        mockTool.safetyLevel = .needsConfirmation
        let sshClient = MockSSHClient()

        let result = await ToolSafetyGate.evaluate(
            toolCall: TestFixtures.makeToolCall(toolName: "rm"),
            tool: mockTool,
            arguments: [:],
            sshClient: sshClient,
            permissionLevel: .standard,
            onConfirmation: { _ in .denied },
            onOutput: { _ in },
            onAgentEvents: { _ in }
        )

        if case .denied = result { } else {
            Issue.record("Expected .denied, got \(result)")
        }
    }

    @Test("forbidden 工具阻止")
    func forbiddenBlocked() async throws {
        let mockTool = MockTool()
        mockTool.safetyLevel = .forbidden
        let sshClient = MockSSHClient()

        let result = await ToolSafetyGate.evaluate(
            toolCall: TestFixtures.makeToolCall(toolName: "rm_rf"),
            tool: mockTool,
            arguments: [:],
            sshClient: sshClient,
            permissionLevel: .standard,
            onConfirmation: { _ in .denied },
            onOutput: { _ in },
            onAgentEvents: { _ in }
        )

        if case .forbidden = result { } else {
            Issue.record("Expected .forbidden, got \(result)")
        }
    }

    @Test("strict 提升 safe → needsConfirmation")
    func strictElevation() async throws {
        let mockTool = MockTool()
        mockTool.safetyLevel = .safe
        mockTool.executeResult = ToolExecutionResult(output: "ok")
        let sshClient = MockSSHClient()

        let confirmationCalled = LockedBox(false)
        let result = await ToolSafetyGate.evaluate(
            toolCall: TestFixtures.makeToolCall(toolName: "ls"),
            tool: mockTool,
            arguments: [:],
            sshClient: sshClient,
            permissionLevel: .strict,
            onConfirmation: { _ in
                confirmationCalled.set(true)
                return .approvedOnce
            },
            onOutput: { _ in },
            onAgentEvents: { _ in }
        )

        #expect(confirmationCalled.value)
        if case .executed = result { } else {
            Issue.record("Expected .executed, got \(result)")
        }
    }

    @Test("permissive 降级 needsConfirmation → safe")
    func permissiveDowngrade() async throws {
        let mockTool = MockTool()
        mockTool.safetyLevel = .needsConfirmation
        mockTool.executeResult = ToolExecutionResult(output: "ok")
        let sshClient = MockSSHClient()

        let confirmationCalled = LockedBox(false)
        let result = await ToolSafetyGate.evaluate(
            toolCall: TestFixtures.makeToolCall(toolName: "write"),
            tool: mockTool,
            arguments: [:],
            sshClient: sshClient,
            permissionLevel: .permissive,
            onConfirmation: { _ in
                confirmationCalled.set(true)
                return .approvedOnce
            },
            onOutput: { _ in },
            onAgentEvents: { _ in }
        )

        #expect(!confirmationCalled.value)
        if case .executed(_, let hadWrite) = result {
            #expect(hadWrite == false) // permissive 降级为 safe，hadWrite 应为 false
        } else {
            Issue.record("Expected .executed, got \(result)")
        }
    }

    @Test("工具执行错误返回 executionError")
    func executionErrorHandled() async throws {
        let mockTool = MockTool()
        mockTool.safetyLevel = .safe
        mockTool.executeError = SSHError.commandFailed("test failure")
        let sshClient = MockSSHClient()

        let result = await ToolSafetyGate.evaluate(
            toolCall: TestFixtures.makeToolCall(toolName: "test"),
            tool: mockTool,
            arguments: [:],
            sshClient: sshClient,
            permissionLevel: .standard,
            onConfirmation: { _ in .denied },
            onOutput: { _ in },
            onAgentEvents: { _ in }
        )

        if case .executionError(let msg) = result {
            #expect(msg.contains("ERROR:"))
        } else {
            Issue.record("Expected .executionError, got \(result)")
        }
    }

    @Test("forbidden 工具不调用 execute")
    func forbiddenDoesNotExecute() async throws {
        let mockTool = MockTool()
        mockTool.safetyLevel = .forbidden
        let sshClient = MockSSHClient()

        _ = await ToolSafetyGate.evaluate(
            toolCall: TestFixtures.makeToolCall(toolName: "rm_rf"),
            tool: mockTool,
            arguments: [:],
            sshClient: sshClient,
            permissionLevel: .standard,
            onConfirmation: { _ in .denied },
            onOutput: { _ in },
            onAgentEvents: { _ in }
        )

        #expect(mockTool.executeCalled == 0)
    }

    @Test("denied 工具不调用 execute")
    func deniedDoesNotExecute() async throws {
        let mockTool = MockTool()
        mockTool.safetyLevel = .needsConfirmation
        let sshClient = MockSSHClient()

        _ = await ToolSafetyGate.evaluate(
            toolCall: TestFixtures.makeToolCall(toolName: "write"),
            tool: mockTool,
            arguments: [:],
            sshClient: sshClient,
            permissionLevel: .standard,
            onConfirmation: { _ in .denied },
            onOutput: { _ in },
            onAgentEvents: { _ in }
        )

        #expect(mockTool.executeCalled == 0)
    }
}
