/// 文件说明：MessageBuilderTests，验证 Message 到 OpenAI 协议格式的转换。
import Testing
@testable import ConchTalk

@Suite("MessageBuilder")
struct MessageBuilderTests {

    @Test("user 消息转换")
    func userMessageConversion() {
        let messages = [TestFixtures.makeMessage(role: .user, content: "hello")]
        let result = MessageBuilder.build(from: messages)
        #expect(result.count == 1)
        #expect(result[0]["role"] as? String == "user")
        #expect(result[0]["content"] as? String == "hello")
    }

    @Test("assistant 消息默认不含 reasoning")
    func assistantNoReasoning() {
        let messages = [TestFixtures.makeMessage(role: .assistant, content: "hi", reasoningContent: "think")]
        let result = MessageBuilder.build(from: messages)
        #expect(result[0]["reasoning_content"] == nil)
    }

    @Test("includeReasoningOnPlainAssistantMessages 时 assistant 含 reasoning_content")
    func assistantWithReasoning() {
        let messages = [TestFixtures.makeMessage(role: .assistant, content: "hi", reasoningContent: "think")]
        let options = MessageBuilderOptions(includeReasoningOnPlainAssistantMessages: true)
        let result = MessageBuilder.build(from: messages, options: options)
        #expect(result[0]["reasoning_content"] as? String == "think")
    }

    @Test("includeReasoningOnToolCalls 时 command 含 reasoning_content")
    func commandWithReasoning() {
        let toolCall = TestFixtures.makeToolCall(toolName: "ls")
        let messages = [TestFixtures.makeMessage(role: .command, content: "", toolCall: toolCall, toolOutput: "file.txt", reasoningContent: "think")]
        let options = MessageBuilderOptions(includeReasoningOnToolCallMessages: true)
        let result = MessageBuilder.build(from: messages, options: options)
        #expect(result.count == 2) // assistant(tool_calls) + tool(result)
        #expect(result[0]["reasoning_content"] as? String == "think")
    }

    @Test("command 消息生成 assistant+tool 两条消息")
    func commandMessageStructure() {
        let toolCall = TestFixtures.makeToolCall(id: "call_abc", toolName: "execute_ssh_command")
        let messages = [TestFixtures.makeMessage(role: .command, content: "", toolCall: toolCall, toolOutput: "output")]
        let result = MessageBuilder.build(from: messages)
        #expect(result.count == 2)
        // 第一条：assistant with tool_calls
        #expect(result[0]["role"] as? String == "assistant")
        let toolCalls = result[0]["tool_calls"] as? [[String: Any]]
        #expect(toolCalls?.count == 1)
        #expect(toolCalls?[0]["id"] as? String == "call_abc")
        // 第二条：tool result
        #expect(result[1]["role"] as? String == "tool")
        #expect(result[1]["tool_call_id"] as? String == "call_abc")
        #expect(result[1]["content"] as? String == "output")
    }

    @Test("tool output 超长截断")
    func toolOutputTruncation() {
        let longOutput = String(repeating: "x", count: 40_000)
        let toolCall = TestFixtures.makeToolCall(toolName: "cat")
        let messages = [TestFixtures.makeMessage(role: .command, content: "", toolCall: toolCall, toolOutput: longOutput)]
        let result = MessageBuilder.build(from: messages)
        let toolMessage = result[1]
        let content = toolMessage["content"] as? String ?? ""
        #expect(content.count < 35_000)
        #expect(content.contains("truncated"))
    }

    @Test("loading 消息被过滤")
    func loadingFiltered() {
        let messages = [
            TestFixtures.makeMessage(role: .user, content: "hello"),
            TestFixtures.makeMessage(role: .assistant, content: "", isLoading: true),
        ]
        let result = MessageBuilder.build(from: messages)
        #expect(result.count == 1)
    }

    @Test("system 消息转为 user 角色")
    func systemToUser() {
        let messages = [TestFixtures.makeMessage(role: .system, content: "info")]
        let result = MessageBuilder.build(from: messages)
        #expect(result[0]["role"] as? String == "user")
        #expect((result[0]["content"] as? String)?.contains("System") == true)
    }

    @Test("空历史返回空数组")
    func emptyHistory() {
        let result = MessageBuilder.build(from: [])
        #expect(result.isEmpty)
    }

    @Test("command 无 toolCall 时跳过")
    func commandWithoutToolCall() {
        let messages = [TestFixtures.makeMessage(role: .command, content: "no tool")]
        let result = MessageBuilder.build(from: messages)
        #expect(result.isEmpty)
    }
}
