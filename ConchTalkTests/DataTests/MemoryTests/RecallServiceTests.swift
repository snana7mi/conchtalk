/// 文件说明：RecallServiceTests，覆盖 RecallService.scoreEntry 的关键词匹配与时间衰减逻辑。
import Testing
@testable import ConchTalk
import Foundation

@Suite("RecallService")
struct RecallServiceTests {
    let now = Date()

    // MARK: - scoreEntry 测试

    @Test("实体匹配得分最高")
    func entityMatchScoresHighest() {
        let entry = MemoryEntry(
            serverID: UUID(),
            content: "Some text",
            tags: [],
            entities: ["nginx"],
            createdAt: now
        )
        let score = RecallService.scoreEntry(entry, keywords: ["nginx"], now: now)
        // 实体匹配 +3.0，无衰减（刚创建）
        #expect(score > 2.9 && score <= 3.0)
    }

    @Test("标签匹配得分 2.0")
    func tagMatchScores() {
        let entry = MemoryEntry(
            serverID: UUID(),
            content: "Some text",
            tags: ["web"],
            entities: [],
            createdAt: now
        )
        let score = RecallService.scoreEntry(entry, keywords: ["web"], now: now)
        #expect(score > 1.9 && score <= 2.0)
    }

    @Test("仅内容匹配得分 1.0")
    func contentMatchScores() {
        let entry = MemoryEntry(
            serverID: UUID(),
            content: "nginx is running on port 80",
            tags: [],
            entities: [],
            createdAt: now
        )
        let score = RecallService.scoreEntry(entry, keywords: ["nginx"], now: now)
        #expect(score > 0.9 && score <= 1.0)
    }

    @Test("无匹配返回 0")
    func noMatchReturnsZero() {
        let entry = MemoryEntry(
            serverID: UUID(),
            content: "nginx is running",
            tags: ["web"],
            entities: ["nginx"],
            createdAt: now
        )
        let score = RecallService.scoreEntry(entry, keywords: ["docker", "redis"], now: now)
        #expect(score == 0)
    }

    @Test("最近条目得分高于旧条目")
    func recentEntriesScoreHigher() {
        let recentEntry = MemoryEntry(
            serverID: UUID(),
            content: "nginx is running",
            tags: [],
            entities: [],
            createdAt: now
        )
        // 60 天前创建
        let oldEntry = MemoryEntry(
            serverID: UUID(),
            content: "nginx is running",
            tags: [],
            entities: [],
            createdAt: now.addingTimeInterval(-60 * 86400)
        )

        let recentScore = RecallService.scoreEntry(recentEntry, keywords: ["nginx"], now: now)
        let oldScore = RecallService.scoreEntry(oldEntry, keywords: ["nginx"], now: now)

        #expect(recentScore > oldScore)
    }

    @Test("30 天后得分约为初始得分的一半")
    func thirtyDayHalfLife() {
        let freshEntry = MemoryEntry(
            serverID: UUID(),
            content: "nginx is running",
            tags: [],
            entities: [],
            createdAt: now
        )
        let oldEntry = MemoryEntry(
            serverID: UUID(),
            content: "nginx is running",
            tags: [],
            entities: [],
            createdAt: now.addingTimeInterval(-30 * 86400)
        )

        let freshScore = RecallService.scoreEntry(freshEntry, keywords: ["nginx"], now: now)
        let oldScore = RecallService.scoreEntry(oldEntry, keywords: ["nginx"], now: now)

        // 30 天半衰期，旧分数约为新的 50%（±10%）
        let ratio = oldScore / freshScore
        #expect(ratio > 0.40 && ratio < 0.60)
    }

    @Test("多关键词累积得分")
    func multipleKeywordsAccumulate() {
        let entry = MemoryEntry(
            serverID: UUID(),
            content: "nginx is running on port 80",
            tags: ["web"],
            entities: ["nginx"],
            createdAt: now
        )
        // nginx: 实体 +3 + 内容 +1 = 4，web: 标签 +2，共 6.0（乘以近似为 1 的衰减）
        let score = RecallService.scoreEntry(entry, keywords: ["nginx", "web"], now: now)
        #expect(score > 5.9 && score <= 6.0)
    }
}
