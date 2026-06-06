/// 文件说明：SubagentResult，子 agent 执行结果。
import Foundation

/// SubagentResult：一个 subagent 执行完成后的结果。
nonisolated struct SubagentResult: Sendable {
    let subagentName: String
    let task: String
    /// 子 agent 最终结论文本（成功时非空）。
    let outcome: String
    let succeeded: Bool
    /// 失败时的精炼错误描述。
    let errorSummary: String?
}
