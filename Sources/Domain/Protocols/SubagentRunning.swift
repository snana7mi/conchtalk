/// 文件说明：SubagentRunning，子 agent 编排的抽象契约。
import Foundation

/// SubagentRunning：
/// 把一批 subagent 任务执行并返回结果。抽象出来便于主循环依赖注入与单测打桩。
/// - Note: 标记 `nonisolated` 与同层 Domain 协议（AIServiceProtocol/ToolProtocol 等）保持一致，
///   使 `nonisolated` 的 SubagentRunner 能在严格并发（默认 MainActor 隔离）下干净地实现。
nonisolated protocol SubagentRunning: Sendable {
    /// 执行一批任务并按输入顺序返回对应结果。
    /// - Parameter tasks: 待分派的子 agent 任务列表。
    /// - Returns: 与 `tasks` 顺序一一对应的结果列表。
    func run(tasks: [SubagentTask]) async -> [SubagentResult]
}
