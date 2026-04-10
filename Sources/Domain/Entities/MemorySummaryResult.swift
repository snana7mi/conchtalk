/// 文件说明：MemorySummaryResult，AI 记忆提取的三层摘要结果。
import Foundation

/// MemorySummaryResult：AI 从对话中提取的三层记忆摘要。
nonisolated struct MemorySummaryResult: Sendable {
    let conversationMemory: String?
    let serverMemory: String?
    let globalMemory: String?
}
