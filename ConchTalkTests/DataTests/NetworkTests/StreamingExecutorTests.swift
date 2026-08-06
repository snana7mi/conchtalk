/// 文件说明：StreamingExecutorTests，验证流式请求自愈逻辑。
import Testing
@testable import ConchTalk

@Suite("StreamingExecutor")
struct StreamingExecutorTests {

    @Test("reasoningHealingHint 识别 missing reasoning_content")
    func healingHintMissing() {
        let hint = StreamingExecutor.reasoningHealingHint(from: "Missing reasoning_content in messages")
        #expect(hint == .add)
    }

    @Test("reasoningHealingHint 识别 missing thinking block")
    func healingHintMissingThinking() {
        let hint = StreamingExecutor.reasoningHealingHint(from: "Missing thinking block")
        #expect(hint == .add)
    }

    @Test("reasoningHealingHint 识别 reasoning_content not allowed")
    func healingHintNotAllowed() {
        let hint = StreamingExecutor.reasoningHealingHint(from: "reasoning_content is not allowed for this model")
        #expect(hint == .remove)
    }

    @Test("reasoningHealingHint 识别 thinking invalid")
    func healingHintThinkingInvalid() {
        let hint = StreamingExecutor.reasoningHealingHint(from: "thinking field is invalid")
        #expect(hint == .remove)
    }

    @Test("reasoningHealingHint 无关错误返回 nil")
    func healingHintUnrelated() {
        let hint = StreamingExecutor.reasoningHealingHint(from: "rate limit exceeded")
        #expect(hint == nil)
    }

    @Test("ReasoningHealingHint 相等性")
    func healingHintEquality() {
        #expect(ReasoningHealingHint.add == ReasoningHealingHint.add)
        #expect(ReasoningHealingHint.add != ReasoningHealingHint.remove)
    }
}
