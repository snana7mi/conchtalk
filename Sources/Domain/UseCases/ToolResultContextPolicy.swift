/// 文件说明：ToolResultContextPolicy，工具输出进入模型上下文前的分层裁剪策略（超大输出头尾截断 + 旧结果分批清理）。
import Foundation

/// ToolResultContextPolicy：
/// 纯函数策略，MessageBuilder 构建请求与 ContextBuilder 估算 token 时共用，保证两边口径一致。
///
/// 分层（由轻到重）：
/// 1. **头尾截断**：单条输出超过 `maxToolOutputChars` 时保留开头 60% + 结尾 40%，
///    中间标注省略字数（错误信息、退出状态、汇总行通常在结尾，旧实现只保留开头会丢掉它们）。
/// 2. **旧结果清理**：同一会话内除最近 `keepRecentResults` 条外，较大的旧工具输出替换为简短存根
///   （保留头尾预览，提示模型需要时重新执行）。清理边界按 `clearingBatch` 分批推进，
///    避免每轮都改动更早的消息而让提示缓存（prompt caching）频繁失效。
/// 3. 跨用户轮次的衰减（MessageBuilder 原有规则）与摘要压缩（ContextCompactor）不变。
nonisolated enum ToolResultContextPolicy {
    /// 单条工具输出发给模型的字符上限。
    static let maxToolOutputChars = 32_000
    /// 头尾截断时开头所占比例。
    static let headShare = 0.6
    /// 始终完整保留的最近工具结果条数。
    static let keepRecentResults = 8
    /// 清理边界每次推进的条数（缓存友好）。
    static let clearingBatch = 4
    /// 小于此字符数的旧输出不清理（存根本身也有开销，且小输出信息密度高）。
    static let clearableMinChars = 2_000
    /// 清理存根中保留的开头 / 结尾预览字符数。
    static let clearedHeadChars = 300
    static let clearedTailChars = 200

    /// 超长文本保留头尾，中间以省略标记替换。
    static func headTail(_ text: String, limit: Int = maxToolOutputChars) -> String {
        guard text.count > limit, limit > 0 else { return text }
        let headCount = Int(Double(limit) * headShare)
        let tailCount = limit - headCount
        let omitted = text.count - headCount - tailCount
        return String(text.prefix(headCount))
            + "\n\n… [\(omitted) characters omitted from the middle of this output] …\n\n"
            + String(text.suffix(tailCount))
    }

    /// 旧工具输出的清理存根。
    static func clearedStub(toolName: String, output: String) -> String {
        let head = String(output.prefix(clearedHeadChars))
        let tail = String(output.suffix(clearedTailChars))
        return "[Older \(toolName) output cleared to save context (\(output.count) characters). Re-run the tool if you need the full output.]\n"
            + head + "\n…\n" + tail
    }

    /// 按工具结果在会话中的顺序（旧 → 新）返回需要清理的下标。
    /// - Parameter sizes: 每条工具结果的字符数。
    static func clearedIndices(sizes: [Int]) -> Set<Int> {
        let eligible = sizes.count - keepRecentResults
        guard eligible > 0 else { return [] }
        let boundary = (eligible / clearingBatch) * clearingBatch
        guard boundary > 0 else { return [] }
        return Set((0..<boundary).filter { sizes[$0] >= clearableMinChars })
    }
}
