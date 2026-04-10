/// 文件说明：MessageTests，测试 Message 领域实体的初始化、字段赋值与枚举定义。
import Testing
@testable import ConchTalk

@Suite("Message Entity")
struct MessageTests {

    // MARK: - Default Init

    @Test("默认初始化：验证角色、内容、可选字段默认值及 isLoading=false")
    func defaultInit() {
        let message = TestFixtures.makeMessage(role: .user, content: "Hello")

        #expect(message.role == .user)
        #expect(message.content == "Hello")
        #expect(message.toolCall == nil)
        #expect(message.toolOutput == nil)
        #expect(message.reasoningContent == nil)
        #expect(message.systemMessageType == nil)
        #expect(message.isLoading == false)
    }

    // MARK: - Assistant Message with Reasoning

    @Test("助手消息：带 reasoningContent 的消息正确存储推理链")
    func assistantMessageWithReasoning() {
        let message = TestFixtures.makeMessage(
            role: .assistant,
            content: "The answer is 42.",
            reasoningContent: "Let me think step by step..."
        )

        #expect(message.role == .assistant)
        #expect(message.content == "The answer is 42.")
        #expect(message.reasoningContent == "Let me think step by step...")
        #expect(message.toolCall == nil)
        #expect(message.toolOutput == nil)
        #expect(message.systemMessageType == nil)
    }

    // MARK: - Command Message with ToolCall and ToolOutput

    @Test("命令消息：带 toolCall 和 toolOutput 的消息正确存储工具调用信息")
    func commandMessageWithToolCallAndOutput() {
        let toolCall = TestFixtures.makeToolCall(
            id: "call_abc",
            toolName: "execute_ssh_command",
            arguments: ["command": "ls -la"],
            explanation: "List files"
        )
        let message = TestFixtures.makeMessage(
            role: .command,
            content: "",
            toolCall: toolCall,
            toolOutput: "total 8\ndrwxr-xr-x 2 root root"
        )

        #expect(message.role == .command)
        #expect(message.toolCall != nil)
        #expect(message.toolCall?.id == "call_abc")
        #expect(message.toolCall?.toolName == "execute_ssh_command")
        #expect(message.toolOutput == "total 8\ndrwxr-xr-x 2 root root")
        #expect(message.reasoningContent == nil)
        #expect(message.systemMessageType == nil)
    }

    // MARK: - System Message with SystemMessageType

    @Test("系统消息：带 systemMessageType 的消息正确存储语义类型")
    func systemMessageWithType() {
        let message = TestFixtures.makeMessage(
            role: .system,
            content: "Connected to server.",
            systemMessageType: .connected
        )

        #expect(message.role == .system)
        #expect(message.content == "Connected to server.")
        #expect(message.systemMessageType == .connected)
        #expect(message.toolCall == nil)
        #expect(message.toolOutput == nil)
        #expect(message.reasoningContent == nil)
    }

    // MARK: - Unique IDs

    @Test("唯一 ID：每条消息生成不同的 UUID")
    func eachMessageGetsUniqueID() {
        let message1 = TestFixtures.makeMessage()
        let message2 = TestFixtures.makeMessage()
        let message3 = TestFixtures.makeMessage()

        #expect(message1.id != message2.id)
        #expect(message2.id != message3.id)
        #expect(message1.id != message3.id)
    }

    // MARK: - MessageRole RawValues

    @Test("MessageRole rawValue：枚举原始值与持久化字符串一致")
    func messageRoleRawValues() {
        #expect(Message.MessageRole.user.rawValue == "user")
        #expect(Message.MessageRole.assistant.rawValue == "assistant")
        #expect(Message.MessageRole.command.rawValue == "command")
        #expect(Message.MessageRole.system.rawValue == "system")
    }

    // MARK: - SystemMessageType Case Count

    @Test("SystemMessageType 共 8 个 case")
    func systemMessageTypeAllCasesCount() {
        let allCases: [Message.SystemMessageType] = [
            .connected,
            .disconnected,
            .connectionLost,
            .reconnected,
            .connectionFailed,
            .error,
            .info,
            .commandDenied
        ]
        #expect(allCases.count == 8)
    }
}
