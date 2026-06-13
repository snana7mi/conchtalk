/// 文件说明：ContextBuilder，组装发送给 AI 的完整上下文。
import Foundation

/// BuiltContext：
/// 上下文构建结果，包含系统提示、记忆块、裁剪后的消息列表及 token 估算信息。
struct BuiltContext: Sendable {
    /// 最终系统提示（含记忆注入）。
    let systemPrompt: String
    /// 记忆上下文文本。
    let memoryContext: String
    /// 经过 token 预算裁剪后的历史消息列表。
    let messages: [Message]
    /// 估算的总 token 数。
    let estimatedTokens: Int
    /// 历史消息预算不足，需要压缩。
    let needsCompaction: Bool
}

/// ContextBuilder：
/// 组装发送给 AI 的完整上下文：system prompt + 记忆 + 对话历史。
/// 根据 maxContextTokens 估算 token 预算，标记是否需要触发上下文压缩。
struct ContextBuilder: Sendable {
    /// 触发压缩的剩余 token 阈值，与 ContextCompactor.compactionThreshold 对齐。
    nonisolated static let compactionReserve = 20_000

    private let memoryContextProvider: any MemoryContextProvider
    private let tokenEstimator: TokenEstimator

    init(
        memoryContextProvider: any MemoryContextProvider,
        tokenEstimator: TokenEstimator = TokenEstimator()
    ) {
        self.memoryContextProvider = memoryContextProvider
        self.tokenEstimator = tokenEstimator
    }

    /// 构建完整上下文：system prompt + 记忆 + 对话历史。
    /// - Parameters:
    ///   - serverID: 服务器 ID，用于查询记忆。
    ///   - userInput: 本轮用户输入（暂不用于语义检索，预留扩展）。
    ///   - systemPrompt: 基础系统提示词。
    ///   - messages: 完整历史消息列表。
    ///   - maxContextTokens: 允许的最大 token 数。
    /// - Returns: 构建好的 BuiltContext，包含压缩必要性标记。
    func buildContext(
        serverID: UUID,
        userInput: String,
        systemPrompt: String,
        messages: [Message],
        maxContextTokens: Int
    ) async -> BuiltContext {
        // 获取记忆上下文
        let memoryContext = await memoryContextProvider.buildMemoryContext(serverID: serverID, userInput: userInput)

        // 估算固定开销：系统提示 + 记忆块
        let fixedTokens = tokenEstimator.estimateTokens(systemPrompt)
            + (memoryContext.isEmpty ? 0 : tokenEstimator.estimateTokens(memoryContext))

        // 估算历史消息 token 总数（含 toolOutput / reasoning）
        let historyTokens = estimateMessagesTokens(messages)
        let estimatedTokens = fixedTokens + historyTokens

        // 需要压缩的判定必须把历史消息算进去：剩余预算（窗口 - 实际总量）不足以
        // 容纳本轮输入 + 期望输出时即触发。reserve 与 ContextCompactor.compactionThreshold 对齐，
        // 避免两层阈值各自为政。旧实现只用 fixedTokens 判定，历史无限增长也几乎永不触发。
        let needsCompaction = (maxContextTokens - estimatedTokens) < Self.compactionReserve

        return BuiltContext(
            systemPrompt: systemPrompt,
            memoryContext: memoryContext,
            messages: messages,
            estimatedTokens: estimatedTokens,
            needsCompaction: needsCompaction
        )
    }

    /// 仅估算 systemPrompt + 历史消息的 token 并判定是否需压缩。
    /// 不查询记忆——buildContext 每次调用都会查记忆（buildMemoryContext），
    /// 循环内每轮调用应避免该开销；阈值复用 compactionReserve，与开头判定一致。
    nonisolated func estimateCompactionNeed(
        systemPrompt: String,
        messages: [Message],
        maxContextTokens: Int
    ) -> (estimatedTokens: Int, needsCompaction: Bool) {
        let tokens = tokenEstimator.estimateTokens(systemPrompt) + estimateMessagesTokens(messages)
        return (tokens, (maxContextTokens - tokens) < Self.compactionReserve)
    }

    /// 估算消息列表的 token 总数（含 toolOutput / reasoningContent）。
    nonisolated private func estimateMessagesTokens(_ messages: [Message]) -> Int {
        messages.reduce(0) { total, msg in
            total + tokenEstimator.estimateTokens(for: msg)
        }
    }
}
