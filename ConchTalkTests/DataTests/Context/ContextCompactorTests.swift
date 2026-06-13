/// 文件说明：ContextCompactorTests，验证上下文压缩摘要消息的类型与内容。
import Testing
@testable import ConchTalk
import Foundation

@Suite("ContextCompactor")
struct ContextCompactorTests {

    /// 构造可触发压缩的 ContextCompactor 及全内存依赖。
    private func makeCompactor(summaryText: String) -> ContextCompactor {
        let aiService = MockAIService()
        aiService.simpleMessageResult = summaryText
        let memoryService = MockMemoryService()
        let entryStore = MockMemoryEntryStore()
        let retainService = RetainService(
            aiService: aiService,
            memoryWriter: memoryService,
            entryStore: entryStore
        )
        let reflectService = ReflectService(
            aiService: aiService,
            entryStore: entryStore,
            memoryWriter: memoryService,
            memoryReader: memoryService
        )
        return ContextCompactor(
            aiService: aiService,
            retainService: retainService,
            reflectService: reflectService
        )
    }

    /// 构造超出近期预算（recentTokenBudget = 20k）的消息列表：
    /// 30 条 × 约 1000 token（4000 个 ASCII 字符），尾部约 20 条进 recent，头部成为待压缩旧消息。
    private func makeLargeHistory() -> [Message] {
        let filler = String(repeating: "x", count: 4_000)
        return (0..<30).map { i in
            TestFixtures.makeMessage(role: i % 2 == 0 ? .user : .assistant, content: filler)
        }
    }

    @Test("压缩摘要消息使用 .aiContext 类型且包含摘要全文")
    func compactIfNeeded_summaryMessageUsesAIContextType() async throws {
        let compactor = makeCompactor(summaryText: "FAKE SUMMARY OF EARLIER WORK")

        // remaining = 100_000 - 90_000 = 10_000 < compactionThreshold(20_000) → 触发压缩
        let result = await compactor.compactIfNeeded(
            serverID: UUID(),
            messages: makeLargeHistory(),
            maxContextTokens: 100_000,
            currentTokens: 90_000
        )

        let compaction = try #require(result)
        let summaryMessage = try #require(compaction.compactedMessages.first)
        #expect(summaryMessage.role == .system)
        #expect(summaryMessage.systemMessageType == .aiContext)
        #expect(summaryMessage.content.contains("FAKE SUMMARY OF EARLIER WORK"))
        #expect(summaryMessage.content.contains("[Context compacted"))
    }

    @Test("剩余预算充足时不压缩")
    func compactIfNeeded_skipsWhenBudgetSufficient() async {
        let compactor = makeCompactor(summaryText: "UNUSED")
        let result = await compactor.compactIfNeeded(
            serverID: UUID(),
            messages: makeLargeHistory(),
            maxContextTokens: 100_000,
            currentTokens: 10_000
        )
        #expect(result == nil)
    }
}
