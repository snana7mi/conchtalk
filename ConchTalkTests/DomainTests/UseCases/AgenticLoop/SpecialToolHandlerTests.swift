/// 文件说明：SpecialToolHandlerTests，验证特殊 tool 拦截逻辑。
import Testing
@testable import ConchTalk

@Suite("SpecialToolHandler")
struct SpecialToolHandlerTests {

    // MARK: - suggest_agent_connection

    @Test("agent connection confirmed 返回 exitLoop")
    func agentConnectionConfirmed() async {
        let toolCall = TestFixtures.makeToolCall(
            toolName: "suggest_agent_connection",
            arguments: ["agent": "opencode", "reason": "coding task"]
        )

        let result = await SpecialToolHandler.handleSuggestAgentConnection(
            toolCall: toolCall,
            reasoning: nil,
            callback: { _, _, _, _ in .confirmed(cwd: nil) }
        )

        if case .exitLoop = result.interceptResult {
            // Expected
        } else {
            Issue.record("Expected exitLoop for confirmed")
        }
        #expect(!result.constructedMessages.isEmpty)
        // confirmed 应产生 2 条消息：初始建议 + 确认完成
        #expect(result.constructedMessages.count == 2)
    }

    @Test("agent connection cancelled 返回 continueLoop")
    func agentConnectionCancelled() async {
        let toolCall = TestFixtures.makeToolCall(
            toolName: "suggest_agent_connection",
            arguments: ["agent": "opencode"]
        )

        let result = await SpecialToolHandler.handleSuggestAgentConnection(
            toolCall: toolCall,
            reasoning: nil,
            callback: { _, _, _, _ in .cancelled }
        )

        if case .continueLoop(let output) = result.interceptResult {
            #expect(output.contains("cancelled"))
        } else {
            Issue.record("Expected continueLoop for cancelled")
        }
        // cancelled 应产生 2 条消息：初始建议 + 取消结果（确保 AI 能看到取消信息）
        #expect(result.constructedMessages.count == 2)
    }

    @Test("agent connection unsupported 返回 continueLoop 并提示 SSH")
    func agentConnectionUnsupported() async {
        let toolCall = TestFixtures.makeToolCall(
            toolName: "suggest_agent_connection",
            arguments: ["agent": "unknown_agent"]
        )

        let result = await SpecialToolHandler.handleSuggestAgentConnection(
            toolCall: toolCall,
            reasoning: nil,
            callback: { _, _, _, _ in .unsupported }
        )

        if case .continueLoop(let output) = result.interceptResult {
            #expect(output.contains("ACP protocol"))
        } else {
            Issue.record("Expected continueLoop for unsupported")
        }
        // unsupported 应产生 2 条消息：初始建议 + 不支持结果
        #expect(result.constructedMessages.count == 2)
    }

    @Test("agent connection customPath 返回 continueLoop")
    func agentConnectionCustomPath() async {
        let toolCall = TestFixtures.makeToolCall(
            toolName: "suggest_agent_connection",
            arguments: ["agent": "opencode"]
        )

        let result = await SpecialToolHandler.handleSuggestAgentConnection(
            toolCall: toolCall,
            reasoning: nil,
            callback: { _, _, _, _ in .customPath }
        )

        if case .continueLoop(let output) = result.interceptResult {
            #expect(output.contains("custom working directory"))
        } else {
            Issue.record("Expected continueLoop for customPath")
        }
        // customPath 应产生 2 条消息：初始建议 + 自定义路径提示
        #expect(result.constructedMessages.count == 2)
    }

    @Test("agent connection 参数正确传递给回调")
    func agentConnectionParametersPassed() async {
        let toolCall = TestFixtures.makeToolCall(
            toolName: "suggest_agent_connection",
            arguments: [
                "agent": "opencode",
                "cwd": "/home/user/project",
                "directories": ["/home/user/project", "/tmp"],
                "home_path": "/home/user"
            ]
        )

        let receivedAgent = LockedBox<String?>(nil)
        let receivedCwd = LockedBox<String?>(nil)
        let receivedDirs = LockedBox<[String]?>(nil)
        let receivedHome = LockedBox<String?>(nil)

        _ = await SpecialToolHandler.handleSuggestAgentConnection(
            toolCall: toolCall,
            reasoning: "test reasoning",
            callback: { agent, cwd, dirs, home in
                receivedAgent.set(agent)
                receivedCwd.set(cwd)
                receivedDirs.set(dirs)
                receivedHome.set(home)
                return .cancelled
            }
        )

        #expect(receivedAgent.value == "opencode")
        #expect(receivedCwd.value == "/home/user/project")
        #expect(receivedDirs.value == ["/home/user/project", "/tmp"])
        #expect(receivedHome.value == "/home/user")
    }

}
