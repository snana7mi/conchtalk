/// 文件说明：ContextBreakIntegrationTests，上下文分割与自动衰减的集成测试。
import Testing
import Foundation
@testable import ConchTalk

/// ContextBreakIntegrationTests：
/// 验证 context break 过滤与 MessageBuilder 衰减协同工作的端到端行为。
struct ContextBreakIntegrationTests {

    // MARK: - context break 过滤 + MessageBuilder 转换

    @Test("break 之后只有 user 消息时，AI 只看到该条消息")
    func contextBreak_aiOnlySeesNewMessages() {
        // 旧消息 + break + 新消息 → AI 只看到新消息
        let oldMessages: [Message] = [
            TestFixtures.makeMessage(role: .user, content: "deploy the app"),
            TestFixtures.makeMessage(
                role: .command, content: "",
                toolCall: TestFixtures.makeToolCall(toolName: "execute_ssh_command"),
                toolOutput: "Error: deployment failed"
            ),
            TestFixtures.makeMessage(role: .assistant, content: "Deployment failed due to..."),
        ]
        let breakMsg = TestFixtures.makeMessage(role: .system, content: "", systemMessageType: .contextBreak)
        let newMessages: [Message] = [
            TestFixtures.makeMessage(role: .user, content: "check disk usage"),
        ]

        let allMessages = oldMessages + [breakMsg] + newMessages
        let filtered = ExecuteNaturalLanguageCommandUseCase.filterAfterLastContextBreak(allMessages)
        let aiMessages = MessageBuilder.build(from: filtered)

        #expect(aiMessages.count == 1)
        #expect(aiMessages.first?["content"] as? String == "check disk usage")
    }

    @Test("衰减 + break 同时存在时，break 优先，旧消息全部不在")
    func decayAndBreak_workTogether() {
        // 构造 5 轮旧消息（本应触发衰减），再插入 break，再加新消息
        var messages: [Message] = []

        for i in 0..<5 {
            messages.append(TestFixtures.makeMessage(role: .user, content: "task \(i)"))
            messages.append(TestFixtures.makeMessage(
                role: .command, content: "",
                toolCall: TestFixtures.makeToolCall(id: "call_\(i)", toolName: "tool_\(i)"),
                toolOutput: "output \(i)"
            ))
            messages.append(TestFixtures.makeMessage(role: .assistant, content: "done \(i)"))
        }

        messages.append(TestFixtures.makeMessage(role: .system, content: "", systemMessageType: .contextBreak))

        messages.append(TestFixtures.makeMessage(role: .user, content: "new task"))
        messages.append(TestFixtures.makeMessage(
            role: .command, content: "",
            toolCall: TestFixtures.makeToolCall(id: "call_new", toolName: "new_tool"),
            toolOutput: "new output"
        ))
        messages.append(TestFixtures.makeMessage(role: .assistant, content: "new done"))

        let filtered = ExecuteNaturalLanguageCommandUseCase.filterAfterLastContextBreak(messages)
        let aiMessages = MessageBuilder.build(from: filtered)

        // break 之后只有 3 条消息 → 转成 AI 格式为 4 条（user + assistant(tool_calls) + tool + assistant）
        let toolContents = aiMessages.compactMap { msg -> String? in
            guard (msg["role"] as? String) == "tool" else { return nil }
            return msg["content"] as? String
        }
        #expect(toolContents.count == 1)
        #expect(toolContents.first == "new output")
    }

    @Test("break 是最后一条消息时，AI 收到空消息列表")
    func emptyAfterBreak_noMessages() {
        let msg = TestFixtures.makeMessage(role: .user, content: "old task")
        let breakMsg = TestFixtures.makeMessage(role: .system, content: "", systemMessageType: .contextBreak)

        let filtered = ExecuteNaturalLanguageCommandUseCase.filterAfterLastContextBreak([msg, breakMsg])
        let aiMessages = MessageBuilder.build(from: filtered)

        #expect(aiMessages.isEmpty)
    }
}
