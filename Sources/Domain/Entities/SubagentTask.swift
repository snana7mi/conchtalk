/// 文件说明：SubagentTask，一次 subagent 分派的任务描述。
import Foundation

/// SubagentTask：主 agent 分派给某个 subagent 的单个任务。
nonisolated struct SubagentTask: Sendable {
    /// 目标 subagent 角色名（对应 SubagentDefinition.name）。
    let subagentType: String
    /// 交给子 agent 执行的任务描述（自然语言）。
    let prompt: String
}
