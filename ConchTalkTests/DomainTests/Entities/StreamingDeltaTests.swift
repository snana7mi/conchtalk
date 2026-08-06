/// 文件说明：StreamingDeltaTests，测试 StreamingDelta 枚举各 case 的构造与模式匹配。
import Testing
@testable import ConchTalk

@Suite("StreamingDelta Entity")
struct StreamingDeltaTests {

    // MARK: - reasoning

    @Test("reasoning case：携带字符串 payload，模式匹配正确提取文本")
    func reasoningCase() {
        let delta = StreamingDelta.reasoning("思考过程文本")
        guard case .reasoning(let text) = delta else {
            #expect(Bool(false), "Expected .reasoning case")
            return
        }
        #expect(text == "思考过程文本")
    }

    // MARK: - content

    @Test("content case：携带字符串 payload，模式匹配正确提取文本")
    func contentCase() {
        let delta = StreamingDelta.content("回复正文内容")
        guard case .content(let text) = delta else {
            #expect(Bool(false), "Expected .content case")
            return
        }
        #expect(text == "回复正文内容")
    }

    // MARK: - toolCall

    @Test("toolCall case：携带 ToolCall payload，模式匹配正确提取工具调用")
    func toolCallCase() {
        let toolCall = TestFixtures.makeToolCall(id: "call_abc", toolName: "execute_ssh_command")
        let delta = StreamingDelta.toolCall(toolCall)
        guard case .toolCall(let tc) = delta else {
            #expect(Bool(false), "Expected .toolCall case")
            return
        }
        #expect(tc.id == "call_abc")
        #expect(tc.toolName == "execute_ssh_command")
    }

    // MARK: - done

    @Test("done case：流正常结束标志，可通过模式匹配识别")
    func doneCase() {
        let delta = StreamingDelta.done
        guard case .done = delta else {
            #expect(Bool(false), "Expected .done case")
            return
        }
    }

    // MARK: - contextCompressing

    @Test("contextCompressing case：上下文压缩标志，可通过模式匹配识别")
    func contextCompressingCase() {
        let delta = StreamingDelta.contextCompressing
        guard case .contextCompressing = delta else {
            #expect(Bool(false), "Expected .contextCompressing case")
            return
        }
    }

    // MARK: - error

    @Test("error case：携带 Error payload，模式匹配正确提取错误")
    func errorCase() {
        let underlying = ToolError.executionFailed("SSH timeout")
        let delta = StreamingDelta.error(underlying)
        guard case .error(let err) = delta else {
            #expect(Bool(false), "Expected .error case")
            return
        }
        guard let toolErr = err as? ToolError else {
            #expect(Bool(false), "Expected ToolError payload")
            return
        }
        guard case .executionFailed(let detail) = toolErr else {
            #expect(Bool(false), "Expected ToolError.executionFailed")
            return
        }
        #expect(detail == "SSH timeout")
    }

    // MARK: - 不同 case 相互不匹配

    @Test("各 case 之间不会误匹配：reasoning 不匹配 content")
    func differentCasesDoNotMatch() {
        let delta = StreamingDelta.reasoning("text")
        var matched = false
        if case .content = delta { matched = true }
        #expect(!matched)
    }
}
