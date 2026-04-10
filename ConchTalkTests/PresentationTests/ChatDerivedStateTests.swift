/// 文件说明：ChatDerivedStateTests，验证派生状态的计算逻辑。
import Testing
@testable import ConchTalk
import Foundation

@Suite("ChatDerivedState")
@MainActor
struct ChatDerivedStateTests {

    @Test("displayMessages 过滤掉 aiContext 系统消息")
    func displayMessages_filtersAIContextMessages() {
        let messages: [Message] = [
            TestFixtures.makeMessage(role: .user, content: "Hello"),
            TestFixtures.makeMessage(role: .system, content: "hidden context", systemMessageType: .aiContext),
            TestFixtures.makeMessage(role: .assistant, content: "Hi there"),
            TestFixtures.makeMessage(role: .system, content: "Connected", systemMessageType: .connected),
        ]

        let derived = ChatDerivedState(messages: messages)

        #expect(derived.displayMessages.count == 3)
        #expect(derived.displayMessages.allSatisfy { $0.systemMessageType != .aiContext })
    }

    @Test("messageIDsBeforeBreak 包含 break 之前的消息 ID")
    func messageIDsBeforeBreak_containsIDsBeforeBreak() {
        let msg1 = TestFixtures.makeMessage(role: .user, content: "Before break")
        let msg2 = TestFixtures.makeMessage(role: .assistant, content: "Also before")
        let breakMsg = TestFixtures.makeMessage(role: .system, content: "", systemMessageType: .contextBreak)
        let msg3 = TestFixtures.makeMessage(role: .user, content: "After break")

        let derived = ChatDerivedState(messages: [msg1, msg2, breakMsg, msg3])

        #expect(derived.messageIDsBeforeBreak.contains(msg1.id))
        #expect(derived.messageIDsBeforeBreak.contains(msg2.id))
        #expect(!derived.messageIDsBeforeBreak.contains(breakMsg.id))
        #expect(!derived.messageIDsBeforeBreak.contains(msg3.id))
        #expect(derived.lastContextBreakIndex == 2)
    }

    @Test("无 context break 时 messageIDsBeforeBreak 为空")
    func messageIDsBeforeBreak_emptyWhenNoBreak() {
        let messages: [Message] = [
            TestFixtures.makeMessage(role: .user, content: "Hello"),
            TestFixtures.makeMessage(role: .assistant, content: "Hi"),
        ]

        let derived = ChatDerivedState(messages: messages)

        #expect(derived.messageIDsBeforeBreak.isEmpty)
        #expect(derived.lastContextBreakIndex == nil)
    }

    @Test("空消息列表产生空派生状态")
    func empty_messagesProduceEmptyDerived() {
        let derived = ChatDerivedState(messages: [])

        #expect(derived.displayMessages.isEmpty)
        #expect(derived.messageIDsBeforeBreak.isEmpty)
        #expect(derived.lastContextBreakIndex == nil)
    }

    @Test("消息变更时重新计算派生状态")
    func recalculatesWhenMessagesChange() {
        // 初始：一条用户消息
        let msg1 = TestFixtures.makeMessage(role: .user, content: "Hello")
        var derived = ChatDerivedState(messages: [msg1])

        #expect(derived.displayMessages.count == 1)
        #expect(derived.lastContextBreakIndex == nil)
        #expect(derived.messageIDsBeforeBreak.isEmpty)

        // 添加 aiContext（应被过滤）+ contextBreak + 新消息后重新计算
        let aiCtx = TestFixtures.makeMessage(role: .system, content: "ctx", systemMessageType: .aiContext)
        let breakMsg = TestFixtures.makeMessage(role: .system, content: "", systemMessageType: .contextBreak)
        let msg2 = TestFixtures.makeMessage(role: .assistant, content: "World")
        derived = ChatDerivedState(messages: [msg1, aiCtx, breakMsg, msg2])

        // displayMessages 应过滤掉 aiContext
        #expect(derived.displayMessages.count == 3)
        #expect(derived.displayMessages.allSatisfy { $0.systemMessageType != .aiContext })
        // contextBreak 在索引 2
        #expect(derived.lastContextBreakIndex == 2)
        // msg1 和 aiCtx 在 break 之前
        #expect(derived.messageIDsBeforeBreak.contains(msg1.id))
        #expect(derived.messageIDsBeforeBreak.contains(aiCtx.id))
        #expect(!derived.messageIDsBeforeBreak.contains(breakMsg.id))
        #expect(!derived.messageIDsBeforeBreak.contains(msg2.id))
    }

    @Test("多个 context break 时使用最后一个")
    func multipleBreaks_usesLastBreak() {
        let msg1 = TestFixtures.makeMessage(role: .user, content: "First")
        let break1 = TestFixtures.makeMessage(role: .system, content: "", systemMessageType: .contextBreak)
        let msg2 = TestFixtures.makeMessage(role: .user, content: "Middle")
        let break2 = TestFixtures.makeMessage(role: .system, content: "", systemMessageType: .contextBreak)
        let msg3 = TestFixtures.makeMessage(role: .user, content: "Last")

        let derived = ChatDerivedState(messages: [msg1, break1, msg2, break2, msg3])

        // break2 在索引 3，所以 0, 1, 2 都在 break 之前
        #expect(derived.messageIDsBeforeBreak.contains(msg1.id))
        #expect(derived.messageIDsBeforeBreak.contains(break1.id))
        #expect(derived.messageIDsBeforeBreak.contains(msg2.id))
        #expect(!derived.messageIDsBeforeBreak.contains(break2.id))
        #expect(!derived.messageIDsBeforeBreak.contains(msg3.id))
        #expect(derived.lastContextBreakIndex == 3)
    }
}
