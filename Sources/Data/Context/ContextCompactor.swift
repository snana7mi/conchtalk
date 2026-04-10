/// 文件说明：ContextCompactor，上下文压缩（Memory Flush + 摘要生成 + Pruning）。
import Foundation

/// CompactionResult：
/// 上下文压缩结果，包含摘要消息、压缩后的历史消息列表及裁剪数量。
struct CompactionResult: Sendable {
    /// 对压缩掉的历史生成的摘要文本。
    let summary: String
    /// 压缩后保留的消息列表（摘要系统消息 + 近期消息）。
    let compactedMessages: [Message]
    /// 被裁剪的消息数量。
    let prunedCount: Int
}

/// ContextCompactor：
/// 负责上下文压缩——Memory Flush + 摘要生成 + 轻量 Reflect，
/// 在上下文 token 剩余不足时触发，减少历史消息体积。
actor ContextCompactor {
    private let aiService: any AIServiceProtocol
    private let retainService: RetainService
    private let reflectService: ReflectService
    private let tokenEstimator: TokenEstimator

    /// CompactionSummary：缓存每个服务器的压缩摘要记录。
    struct CompactionSummary {
        let summary: String
        let compactedMessageCount: Int
        let lastCompactionDate: Date
    }

    /// 按服务器 ID 缓存最近一次压缩摘要，避免重复压缩。
    private var summaryCache: [UUID: CompactionSummary] = [:]

    /// 触发压缩的 token 剩余阈值：剩余不足 20000 token 时才压缩。
    private let compactionThreshold = 20_000

    /// 压缩时保留最近消息的 token 上限，约 20000 token。
    private let recentTokenBudget = 20_000

    init(
        aiService: any AIServiceProtocol,
        retainService: RetainService,
        reflectService: ReflectService,
        tokenEstimator: TokenEstimator = TokenEstimator()
    ) {
        self.aiService = aiService
        self.retainService = retainService
        self.reflectService = reflectService
        self.tokenEstimator = tokenEstimator
    }

    /// 按需压缩上下文：仅在剩余 token 低于阈值时触发。
    /// - Note: 调用方应在传入前过滤 contextBreak 之前的消息（由 ExecuteNaturalLanguageCommandUseCase 负责）。
    /// - Parameters:
    ///   - serverID: 服务器 ID。
    ///   - messages: 当前完整历史消息列表。
    ///   - maxContextTokens: 允许的最大 token 数。
    ///   - currentTokens: 当前估算的 token 总数。
    /// - Returns: 压缩结果；若无需压缩则返回 nil。
    func compactIfNeeded(
        serverID: UUID,
        messages: [Message],
        maxContextTokens: Int,
        currentTokens: Int
    ) async -> CompactionResult? {
        let remaining = maxContextTokens - currentTokens
        guard remaining < compactionThreshold else { return nil }

        // 1. Memory Flush：异步提取事实写入记忆（out-of-band，不等待结果）
        let allMessages = messages
        Task.detached { [retainService] in
            await retainService.retain(serverID: serverID, recentMessages: allMessages)
        }

        // 2. 划分「近期消息」与「待压缩消息」
        let (recentMessages, oldMessages) = splitMessages(messages)
        guard !oldMessages.isEmpty else { return nil }

        // 3. 通过 AI 为旧消息生成摘要
        let summaryText = await generateSummary(for: oldMessages)

        // 4. 轻量 Reflect：整合新近记忆条目
        let compactionDate = Date()
        Task.detached { [reflectService] in
            await reflectService.reflectRecent(serverID: serverID, since: compactionDate)
        }

        // 5. 缓存压缩摘要
        summaryCache[serverID] = CompactionSummary(
            summary: summaryText,
            compactedMessageCount: oldMessages.count,
            lastCompactionDate: compactionDate
        )

        // 6. 构建压缩结果：摘要系统消息 + 近期消息
        let summaryMessage = Message(
            role: .system,
            content: "[Context compacted — earlier conversation summary]\n\(summaryText)",
            systemMessageType: .info
        )
        let compactedMessages = [summaryMessage] + recentMessages

        return CompactionResult(
            summary: summaryText,
            compactedMessages: compactedMessages,
            prunedCount: oldMessages.count
        )
    }

    // MARK: - Private Helpers

    /// 按 token 预算将消息列表分为「近期」（尾部）和「旧消息」（头部）两段。
    private func splitMessages(_ messages: [Message]) -> (recent: [Message], old: [Message]) {
        var recentTokens = 0
        var recentCount = 0

        // 从尾部往前累计，直到超出近期预算
        for message in messages.reversed() {
            let tokens = tokenEstimator.estimateTokens(message.content)
            if recentTokens + tokens > recentTokenBudget { break }
            recentTokens += tokens
            recentCount += 1
        }

        let splitIndex = messages.count - recentCount
        let old = Array(messages.prefix(splitIndex))
        let recent = Array(messages.suffix(recentCount))
        return (recent: recent, old: old)
    }

    /// 调用 AI 为旧消息列表生成摘要。
    private func generateSummary(for messages: [Message]) async -> String {
        let conversationText = messages
            .filter { $0.role == .user || $0.role == .assistant }
            .map { "[\($0.role.rawValue)]: \($0.content)" }
            .joined(separator: "\n")

        let prompt = """
        Summarize the following conversation segment concisely. Focus on key decisions, findings, commands executed, and their outcomes. Be factual and specific.

        Return ONLY the summary text (no JSON, no markdown headers, no explanation):

        Conversation:
        \(conversationText)
        """

        return (try? await aiService.sendSimpleMessage(prompt)) ?? "[Summary unavailable]"
    }
}
