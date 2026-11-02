/// 文件说明：ServerBatchTests，覆盖分组批处理的并发上限、结果归属和对比摘要。
import Testing
@testable import ConchTalk
import Foundation

@Suite("Server batch")
struct ServerBatchTests {
    private actor ConcurrencyProbe {
        private var current = 0
        private(set) var maxSeen = 0
        private var entered = 0

        /// 等到至少两个任务同时进来，用来证明上限允许并行；同时记录峰值。
        func enter() async -> Bool {
            current += 1
            entered += 1
            maxSeen = max(maxSeen, current)
            let start = Date()
            while entered < 2 && Date().timeIntervalSince(start) < 1 {
                try? await Task.sleep(for: .milliseconds(10))
            }
            let overlapped = entered >= 2
            current -= 1
            return overlapped
        }
    }

    @Test("并行映射保持输入顺序，并且不超过并发上限")
    func boundedMapPreservesOrderAndCap() async {
        let probe = ConcurrencyProbe()
        let outputs = await BoundedParallelMap.map(Array(0..<4), maxConcurrent: 2) { value in
            let overlapped = await probe.enter()
            return (value, overlapped)
        }
        #expect(outputs.map(\.0) == [0, 1, 2, 3])
        #expect(outputs.contains { $0.1 })
        #expect(await probe.maxSeen <= 2)
        #expect(await probe.maxSeen >= 2)
    }

    @Test("一台失败不会丢掉其他服务器的结果，摘要按服务器分开")
    func isolatesServerResults() async {
        let alpha = TestFixtures.makeServer(name: "Alpha")
        let beta = TestFixtures.makeServer(name: "Beta")
        let executor = ScriptedBatchExecutor(failures: [beta.id])
        let report = await ServerBatchRunner(maxConcurrent: 2).run(
            groupName: "Web",
            servers: [alpha, beta],
            prompt: "Check disk",
            executor: executor
        )

        #expect(report.results.map(\.serverID) == [alpha.id, beta.id])
        #expect(report.results[0].succeeded)
        #expect(!report.results[1].succeeded)
        #expect(report.markdown.contains("Succeeded 1 of 2."))
        #expect(report.markdown.contains("summaries differ"))
        #expect(executor.prompts == ["Check disk", "Check disk"])
        #expect(Set(executor.serverIDs) == Set([alpha.id, beta.id]))
    }

    @Test("相同摘要会写成对比结论，空分组不会调用执行器")
    func comparesIdenticalSummariesAndSkipsEmptyGroup() async {
        let server = TestFixtures.makeServer(name: "Alpha")
        let other = TestFixtures.makeServer(name: "Gamma")
        let executor = ScriptedBatchExecutor(failures: [])
        let report = await ServerBatchRunner().run(
            groupName: "Web",
            servers: [server, other],
            prompt: "Check disk",
            executor: executor
        )
        #expect(report.markdown.contains("every server returned the same summary."))

        let empty = await ServerBatchRunner().run(
            groupName: "Empty",
            servers: [],
            prompt: "Check disk",
            executor: executor
        )
        #expect(empty.results.isEmpty)
        #expect(empty.markdown.contains("No servers in this group."))
        #expect(executor.callCount == 2)
    }

    @Test("空提示词不会发到任何服务器")
    func emptyPromptDoesNotRun() async {
        let executor = ScriptedBatchExecutor(failures: [])
        let report = await ServerBatchRunner().run(
            groupName: "Web",
            servers: [TestFixtures.makeServer()],
            prompt: "   ",
            executor: executor
        )
        #expect(report.results.count == 1)
        #expect(!report.results[0].succeeded)
        #expect(executor.callCount == 0)
    }
}

private final class ScriptedBatchExecutor: ServerBatchExecuting, @unchecked Sendable {
    private let failures: Set<UUID>
    private let lock = NSLock()
    private var recordedServers: [UUID] = []
    private var recordedPrompts: [String] = []

    init(failures: Set<UUID>) {
        self.failures = failures
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return recordedServers.count
    }

    var serverIDs: [UUID] {
        lock.lock()
        defer { lock.unlock() }
        return recordedServers
    }

    var prompts: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedPrompts
    }

    func run(server: Server, prompt: String) async -> ServerBatchServerResult {
        lock.lock()
        recordedServers.append(server.id)
        recordedPrompts.append(prompt)
        lock.unlock()
        let failed = failures.contains(server.id)
        return ServerBatchServerResult(
            serverID: server.id,
            serverName: server.name,
            succeeded: !failed,
            summary: failed ? "disk check failed" : "disk 40%"
        )
    }
}
