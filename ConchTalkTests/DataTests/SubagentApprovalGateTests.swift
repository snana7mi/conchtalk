/// 文件说明：SubagentApprovalGateTests，验证确认请求严格串行（一次一个）。
import Testing
@testable import ConchTalk
import Foundation

@Suite("SubagentApprovalGate")
struct SubagentApprovalGateTests {

    /// 记录回调进入/离开，检测是否出现重叠（并发进入）。
    private actor OverlapDetector {
        private(set) var maxConcurrent = 0
        private var current = 0
        private(set) var order: [String] = []
        func enter(_ id: String) { current += 1; maxConcurrent = max(maxConcurrent, current); order.append(id) }
        func leave() { current -= 1 }
    }

    @Test("并发请求被串行化，回调不重叠")
    func serialized() async {
        let gate = SubagentApprovalGate()
        let detector = OverlapDetector()

        let parentCallback: @Sendable (ToolCall) async -> CommandApproval = { call in
            await detector.enter(call.id)
            try? await Task.sleep(for: .milliseconds(20))
            await detector.leave()
            return .approved
        }

        await withTaskGroup(of: CommandApproval.self) { group in
            for i in 0..<5 {
                let call = TestFixtures.makeToolCall(id: "c\(i)", toolName: "execute_ssh_command", arguments: [:])
                group.addTask { await gate.requestConfirmation(call, via: parentCallback) }
            }
            for await _ in group {}
        }

        let maxConcurrent = await detector.maxConcurrent
        let count = await detector.order.count
        #expect(maxConcurrent == 1)
        #expect(count == 5)
    }

    @Test("透传父回调的结果")
    func passesResult() async {
        let gate = SubagentApprovalGate()
        let call = TestFixtures.makeToolCall(id: "x", toolName: "execute_ssh_command", arguments: [:])
        let result = await gate.requestConfirmation(call, via: { _ in .denied })
        #expect(result == .denied)
    }
}
