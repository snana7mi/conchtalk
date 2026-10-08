/// 文件说明：ToolResultContextPolicyTests，验证分层上下文管理：头尾截断、旧工具结果分批清理、估算口径一致与按模型封顶的上下文预算。
import Foundation
import Testing
@testable import ConchTalk

@Suite("Tiered context management")
struct ToolResultContextPolicyTests {

    private func toolMessage(_ output: String, name: String = "execute_ssh_command") -> Message {
        Message(
            role: .command,
            content: "",
            toolCall: ToolCall(id: UUID().uuidString, toolName: name, argumentsJSON: Data("{}".utf8), explanation: ""),
            toolOutput: output
        )
    }

    private func toolContents(_ built: [[String: Any]]) -> [String] {
        built.filter { $0["role"] as? String == "tool" }.compactMap { $0["content"] as? String }
    }

    @Test("头尾截断：保留开头与结尾，标注省略字数；短文本原样返回")
    func headTailTruncation() {
        let text = "HEAD" + String(repeating: "x", count: 50_000) + "TAIL: exit code 1"
        let cut = ToolResultContextPolicy.headTail(text)
        #expect(cut.hasPrefix("HEAD"))
        #expect(cut.hasSuffix("TAIL: exit code 1"))
        #expect(cut.contains("characters omitted from the middle"))
        #expect(cut.count < ToolResultContextPolicy.maxToolOutputChars + 200)
        #expect(ToolResultContextPolicy.headTail("short") == "short")
    }

    @Test("清理下标：保留最近 N 条，边界按批推进，小输出不清理")
    func clearedIndices() {
        let keep = ToolResultContextPolicy.keepRecentResults
        let batch = ToolResultContextPolicy.clearingBatch
        let big = ToolResultContextPolicy.clearableMinChars
        #expect(ToolResultContextPolicy.clearedIndices(sizes: Array(repeating: big, count: keep)).isEmpty)
        #expect(ToolResultContextPolicy.clearedIndices(sizes: Array(repeating: big, count: keep + batch - 1)).isEmpty)
        #expect(ToolResultContextPolicy.clearedIndices(sizes: Array(repeating: big, count: keep + batch)) == Set(0..<batch))
        // 再多一条，边界不动（缓存友好）
        #expect(ToolResultContextPolicy.clearedIndices(sizes: Array(repeating: big, count: keep + batch + 1)) == Set(0..<batch))
        var mixed = Array(repeating: big, count: keep + batch)
        mixed[1] = 10
        #expect(ToolResultContextPolicy.clearedIndices(sizes: mixed) == Set([0, 2, 3]))
    }

    @Test("同一轮内长任务：旧的大输出被替换为存根，最近结果完整保留")
    func clearsOldResultsWithinRound() {
        let big = String(repeating: "line of output\n", count: 300) // ~4.5K chars
        var history = [Message(role: .user, content: "investigate")]
        for i in 0..<14 {
            history.append(toolMessage("RESULT-\(i)\n" + big))
        }
        let contents = toolContents(MessageBuilder.build(from: history))
        #expect(contents.count == 14)
        // 14 条：可清理 6 条 → 边界 4
        for i in 0..<4 {
            #expect(contents[i].hasPrefix("[Older execute_ssh_command output cleared"))
            #expect(contents[i].contains("RESULT-\(i)"), "存根保留开头预览")
        }
        for i in 4..<14 {
            #expect(contents[i].hasPrefix("RESULT-\(i)"))
            #expect(!contents[i].contains("cleared to save context"))
        }
    }

    @Test("清理边界稳定：新增一条结果时更早的消息内容不变（提示缓存友好）")
    func clearingIsCacheStable() {
        let big = String(repeating: "y", count: 3_000)
        var history = [Message(role: .user, content: "go")]
        for _ in 0..<12 { history.append(toolMessage(big)) }
        let before = toolContents(MessageBuilder.build(from: history))
        history.append(toolMessage(big))
        let after = toolContents(MessageBuilder.build(from: history))
        #expect(Array(after.prefix(before.count)) == before)
    }

    @Test("token 估算按模型可见内容计算，清理后估算下降")
    func estimateUsesVisibleOutputs() {
        let big = String(repeating: "z", count: 20_000)
        var history = [Message(role: .user, content: "go")]
        for _ in 0..<16 { history.append(toolMessage(big)) }
        let builder = ContextBuilder(memoryContextProvider: MockMemoryService())
        let estimated = builder.estimateCompactionNeed(fixedTokens: 0, messages: history, maxContextTokens: 1_000_000).estimatedTokens
        let raw = history.reduce(0) { $0 + TokenEstimator().estimateTokens(for: $1) }
        #expect(estimated < raw)
        // 8 条完整保留 + 8 条存根
        #expect(estimated >= 8 * 20_000 / 4)
    }

    @Test("Claude 上下文窗口：1M 与 200K 分组（官方文档 2026-10）")
    func claudeContextWindows() {
        #expect(AnthropicModelCapabilities.contextWindow(for: "claude-opus-5-5") == 1_000_000)
        #expect(AnthropicModelCapabilities.contextWindow(for: "claude-sonnet-4-6") == 1_000_000)
        #expect(AnthropicModelCapabilities.contextWindow(for: "claude-opus-4-6") == 1_000_000)
        #expect(AnthropicModelCapabilities.contextWindow(for: "claude-haiku-5-5") == 1_000_000)
        #expect(AnthropicModelCapabilities.contextWindow(for: "claude-fable-5-1") == 1_000_000)
        #expect(AnthropicModelCapabilities.contextWindow(for: "claude-mythos-preview") == 1_000_000)
        #expect(AnthropicModelCapabilities.contextWindow(for: "claude-sonnet-4-5-20250929") == 200_000)
        #expect(AnthropicModelCapabilities.contextWindow(for: "claude-haiku-4-5") == 200_000)
        #expect(AnthropicModelCapabilities.contextWindow(for: "claude-opus-4-5") == 200_000)
        #expect(AnthropicModelCapabilities.contextWindow(for: "claude-3-7-sonnet-20250219") == 200_000)
        #expect(AnthropicModelCapabilities.contextWindow(for: "gpt-5") == nil)
    }

    @Test("上下文预算：不超过模型窗口减去输出上限；未知模型沿用用户设置")
    func effectiveBudget() {
        #expect(AISettings.effectiveMaxContextTokens(configured: 128_000, modelName: "claude-haiku-4-5", maxOutputTokens: 16_000) == 128_000)
        #expect(AISettings.effectiveMaxContextTokens(configured: 500_000, modelName: "claude-haiku-4-5", maxOutputTokens: 16_000) == 184_000)
        #expect(AISettings.effectiveMaxContextTokens(configured: 500_000, modelName: "claude-opus-5-5", maxOutputTokens: 32_000) == 500_000)
        #expect(AISettings.effectiveMaxContextTokens(configured: 500_000, modelName: "deepseek-chat", maxOutputTokens: 8_000) == 500_000)

        let suite = "ToolResultContextPolicyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(400, forKey: "aiMaxContextTokensK")
        defaults.set("claude-sonnet-4-5", forKey: "aiModelName")
        #expect(AISettings.loadMaxContextTokens(defaults: defaults) == 200_000 - 16_000)
        defaults.removePersistentDomain(forName: suite)
    }

    @Test("用量紧凑显示支持 M")
    func compactMillions() {
        #expect(DirectContextUsage.compact(1_000_000) == "1M")
        #expect(DirectContextUsage.compact(1_500_000) == "1.5M")
        #expect(DirectContextUsage.compact(200_000) == "200K")
    }
}
