/// 文件说明：ContextBreakFilterTests，验证 ExecuteNaturalLanguageCommandUseCase 的上下文断点过滤逻辑。
import Foundation
import Testing
@testable import ConchTalk

@Suite("Context Break Filter")
struct ContextBreakFilterTests {

    // MARK: - filterAfterLastContextBreak

    @Test("有 contextBreak 时只返回断点之后的消息")
    func filterMessagesAfterContextBreak() {
        let oldMsg = TestFixtures.makeMessage(role: .user, content: "old message")
        let breakMsg = TestFixtures.makeMessage(role: .system, content: "", systemMessageType: .contextBreak)
        let newMsg = TestFixtures.makeMessage(role: .user, content: "new message")
        let messages = [oldMsg, breakMsg, newMsg]

        let result = ExecuteNaturalLanguageCommandUseCase.filterAfterLastContextBreak(messages)

        #expect(result.count == 1)
        #expect(result[0].content == "new message")
    }

    @Test("无 contextBreak 时返回全部消息")
    func noContextBreak_returnsAll() {
        let msg1 = TestFixtures.makeMessage(role: .user, content: "first")
        let msg2 = TestFixtures.makeMessage(role: .assistant, content: "second")
        let messages = [msg1, msg2]

        let result = ExecuteNaturalLanguageCommandUseCase.filterAfterLastContextBreak(messages)

        #expect(result.count == 2)
        #expect(result[0].content == "first")
        #expect(result[1].content == "second")
    }

    @Test("多个 contextBreak 时使用最后一个")
    func multipleBreaks_usesLastOne() {
        let oldMsg = TestFixtures.makeMessage(role: .user, content: "old")
        let break1 = TestFixtures.makeMessage(role: .system, content: "", systemMessageType: .contextBreak)
        let middleMsg = TestFixtures.makeMessage(role: .user, content: "middle")
        let break2 = TestFixtures.makeMessage(role: .system, content: "", systemMessageType: .contextBreak)
        let newMsg = TestFixtures.makeMessage(role: .user, content: "new")
        let messages = [oldMsg, break1, middleMsg, break2, newMsg]

        let result = ExecuteNaturalLanguageCommandUseCase.filterAfterLastContextBreak(messages)

        #expect(result.count == 1)
        #expect(result[0].content == "new")
    }

    @Test("contextBreak 在末尾时返回空数组")
    func breakAtEnd_returnsEmpty() {
        let msg = TestFixtures.makeMessage(role: .user, content: "hello")
        let breakMsg = TestFixtures.makeMessage(role: .system, content: "", systemMessageType: .contextBreak)
        let messages = [msg, breakMsg]

        let result = ExecuteNaturalLanguageCommandUseCase.filterAfterLastContextBreak(messages)

        #expect(result.isEmpty)
    }
}
