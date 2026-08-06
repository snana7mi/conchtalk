/// 文件说明：ACPStreamParser，ACP 流式输出的增量解析器。
///
/// 接收累积文本，通过偏移量追踪只解析新增部分。
/// 值类型，无并发依赖，可在任意线程使用。

import Foundation

/// ACPStreamParser：
/// 将 ACP 流式输出按行增量解析为 AgentStreamEvent。
/// **增量 chunk 模式**：每次调用 `parse(chunk:)` 只传入新到达的片段，
/// 解析器内部维护尚未构成完整行的残留尾巴（`residual`）。
/// 这样每个字符只被处理一次，整体 O(N)——旧实现每次对不断增长的累积全文做
/// `index(offsetBy:)` + `count`，是 O(N²)。
nonisolated struct ACPStreamParser: Sendable {
    /// 尚未构成完整行的残留尾巴（只保存最后一个不完整行，不会随流增长）。
    private var residual: String = ""

    /// 解析新到达的 chunk，返回本次新解析出的事件。
    /// - Parameter chunk: 本次新到达的输出片段（不是累积全文）。
    /// - Returns: 本次新解析出的 AgentStreamEvent 数组。
    mutating func parse(chunk: String) -> [AgentStreamEvent] {
        guard !chunk.isEmpty else { return [] }
        residual += chunk

        var events: [AgentStreamEvent] = []
        let segments = residual.components(separatedBy: "\n")

        // components(separatedBy:) 对 "a\nb\n" 返回 ["a","b",""]，对 "a\nb" 返回 ["a","b"]。
        // dropLast(1) 在两种情况下都正确：完整行全部处理，末尾不完整片段留作 residual。
        for line in segments.dropLast(1) {
            if let event = AgentStreamEvent.decodeFromStreamLine(line) {
                events.append(event)
            }
        }

        // 末尾片段（可能是不完整行）留到下次拼接
        residual = segments.last ?? ""
        return events
    }

    /// 重置解析状态（新一轮工具调用时调用）。
    mutating func reset() {
        residual = ""
    }
}
