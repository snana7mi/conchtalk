/// 文件说明：BoundedParallelMap，带并发上限的并行映射，顺序与输入一致。
import Foundation

/// BoundedParallelMap：
/// 与 `SubagentRunner` 相同的投递方式：先启动不超过上限的任务，每完成一个再补一个。
/// 单个任务的失败由调用方包进结果，不会取消其余任务。取消后不再启动新任务。
nonisolated enum BoundedParallelMap {
    /// subagent 与跨服务器批处理共用的默认并发上限。
    static let defaultMaxConcurrent = 2

    static func map<Input: Sendable, Output: Sendable>(
        _ items: [Input],
        maxConcurrent: Int,
        operation: @escaping @Sendable (Input) async -> Output
    ) async -> [Output] {
        guard !items.isEmpty else { return [] }
        var results = [Output?](repeating: nil, count: items.count)
        let limit = min(max(1, maxConcurrent), items.count)

        await withTaskGroup(of: (Int, Output).self) { group in
            var next = 0
            for _ in 0..<limit {
                let index = next
                next += 1
                let item = items[index]
                _ = group.addTaskUnlessCancelled { (index, await operation(item)) }
            }
            while let (index, output) = await group.next() {
                results[index] = output
                if next < items.count {
                    let index = next
                    next += 1
                    let item = items[index]
                    _ = group.addTaskUnlessCancelled { (index, await operation(item)) }
                }
            }
        }
        return results.compactMap { $0 }
    }
}
