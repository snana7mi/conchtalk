/// 文件说明：ServerBatchRunner，把同一任务按 subagent 的并发上限分发到一组服务器。
import Foundation

/// ServerBatchRunner：
/// 并行度复用 `BoundedParallelMap`（与 subagent 相同的补投策略）。
/// 本类型不批准任何操作。每台服务器的执行器必须单独走该服务器的确认流程，
/// 一台的批准不能写入另一台的结果。
nonisolated struct ServerBatchRunner: Sendable {
    var maxConcurrent: Int

    init(maxConcurrent: Int = BoundedParallelMap.defaultMaxConcurrent) {
        self.maxConcurrent = max(1, maxConcurrent)
    }

    func run(
        groupName: String,
        servers: [Server],
        prompt: String,
        executor: any ServerBatchExecuting
    ) async -> ServerBatchReport {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            let skipped = servers.map {
                ServerBatchServerResult(
                    serverID: $0.id,
                    serverName: $0.name,
                    succeeded: false,
                    summary: "Empty prompt."
                )
            }
            return ServerBatchReportBuilder.make(groupName: groupName, prompt: prompt, results: skipped)
        }
        let results = await BoundedParallelMap.map(servers, maxConcurrent: maxConcurrent) { server in
            await executor.run(server: server, prompt: trimmed)
        }
        return ServerBatchReportBuilder.make(groupName: groupName, prompt: trimmed, results: results)
    }
}
