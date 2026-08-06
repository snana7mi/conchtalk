/// 文件说明：AgentStreamEventTests，验证 ACP 会话更新到内部流式事件的转换。

import Testing
@testable import ConchTalk
@preconcurrency import ACPModel

/// AgentStreamEventTests：
/// 覆盖最新版 ACPModel 新增的计划更新类型，避免依赖升级后出现未处理分支。
@Suite("AgentStreamEvent")
struct AgentStreamEventTests {
    @Test("条目式计划更新转换为计划事件")
    func convertsPlanItemsUpdate() {
        let entry = PlanEntry(
            content: "Inspect dependencies",
            priority: .high,
            status: .inProgress
        )
        let update = SessionUpdate.planUpdate(
            PlanUpdate(plan: .items(PlanItems(planId: "plan-1", entries: [entry])))
        )

        #expect(
            AgentStreamEvent.from(update) == .plan([
                AgentPlanEntry(title: "Inspect dependencies", status: "in_progress")
            ])
        )
    }

    @Test("移除计划更新不生成展示事件")
    func ignoresPlanRemoval() {
        let update = SessionUpdate.planRemoved(PlanRemoved(planId: "plan-1"))

        #expect(AgentStreamEvent.from(update) == nil)
    }
}
