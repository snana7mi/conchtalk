/// 文件说明：RecallService，基于关键词匹配与时间衰减的记忆条目检索服务。
import Foundation

/// RecallService：
/// 根据用户输入从 MemoryEntryStore 中检索最相关的记忆条目。
/// 评分策略：实体匹配 +3.0、标签匹配 +2.0、内容包含 +1.0，叠加 30 天半衰期时间衰减。
/// 根据 tokenBudget 控制返回总 token 量。
actor RecallService {
    private let entryStore: any MemoryEntryStore
    private let tokenEstimator: TokenEstimator
    private let tokenBudget: Int

    init(
        entryStore: any MemoryEntryStore,
        tokenEstimator: TokenEstimator = TokenEstimator(),
        tokenBudget: Int = 2000
    ) {
        self.entryStore = entryStore
        self.tokenEstimator = tokenEstimator
        self.tokenBudget = tokenBudget
    }

    // MARK: - Public API

    /// 根据用户输入检索相关记忆条目，按相关性降序返回，总 token 量不超过 tokenBudget。
    /// - Parameters:
    ///   - serverID: 关联服务器 ID。
    ///   - userInput: 用户当前输入文本。
    /// - Returns: 相关记忆条目列表（已按分数排序并截断）。
    func recall(serverID: UUID, userInput: String) async -> [MemoryEntry] {
        guard let entries = try? await entryStore.fetchMemoryEntries(forServer: serverID),
              !entries.isEmpty else {
            return []
        }

        let keywords = extractKeywords(userInput)
        guard !keywords.isEmpty else { return [] }

        let now = Date()
        // 计算每条记录的分数，过滤掉分数为 0 的
        let scored = entries
            .map { entry in (entry: entry, score: Self.scoreEntry(entry, keywords: keywords, now: now)) }
            .filter { $0.score > 0 }
            .sorted { $0.score > $1.score }

        // 按 token 预算截断
        var result: [MemoryEntry] = []
        var usedTokens = 0
        for item in scored {
            let tokens = tokenEstimator.estimateTokens(item.entry.content)
            if usedTokens + tokens > tokenBudget { break }
            result.append(item.entry)
            usedTokens += tokens
        }
        return result
    }

    // MARK: - Scoring (static for testability)

    /// 计算记忆条目与关键词的相关性分数（含时间衰减）。
    /// - Parameters:
    ///   - entry: 待评分的记忆条目。
    ///   - keywords: 从用户输入提取的关键词列表。
    ///   - now: 当前时间，用于时间衰减计算。
    /// - Returns: 相关性分数（0.0 ~ ∞）；无匹配时为 0。
    static func scoreEntry(_ entry: MemoryEntry, keywords: [String], now: Date) -> Double {
        var baseScore = 0.0
        let lowercasedContent = entry.content.lowercased()
        let lowercasedEntities = entry.entities.map { $0.lowercased() }
        let lowercasedTags = entry.tags.map { $0.lowercased() }

        for keyword in keywords {
            let kw = keyword.lowercased()
            // 实体匹配：+3.0
            if lowercasedEntities.contains(where: { $0.contains(kw) }) {
                baseScore += 3.0
            }
            // 标签匹配：+2.0
            if lowercasedTags.contains(where: { $0.contains(kw) }) {
                baseScore += 2.0
            }
            // 内容包含：+1.0
            if lowercasedContent.contains(kw) {
                baseScore += 1.0
            }
        }

        guard baseScore > 0 else { return 0 }

        // 时间衰减：30 天半衰期，decay = exp(-0.023 * days)
        let daysSinceCreation = now.timeIntervalSince(entry.createdAt) / 86400.0
        let decay = exp(-0.023 * max(daysSinceCreation, 0))
        return baseScore * decay
    }

    // MARK: - Private Helpers

    /// 从文本中提取关键词，CJK 字符最小长度为 1，ASCII 最小长度为 2。
    private func extractKeywords(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }

        var keywords: [String] = []
        // 按空白字符和标点分词
        let separators = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
        let rawWords = text.components(separatedBy: separators).filter { !$0.isEmpty }

        for word in rawWords {
            // 判断是否含 CJK 字符
            let hasCJK = word.unicodeScalars.contains { isCJK($0) }
            let minLength = hasCJK ? 1 : 2
            if word.count >= minLength {
                keywords.append(word)
            }
        }

        // 去重
        return Array(Set(keywords))
    }

    /// 判断 unicode scalar 是否属于 CJK 范围。
    private func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value >= 0x4E00 && scalar.value <= 0x9FFF ||
        scalar.value >= 0x3400 && scalar.value <= 0x4DBF ||
        scalar.value >= 0x3000 && scalar.value <= 0x303F
    }
}
