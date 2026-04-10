/// 文件说明：ACPStreamParser，ACP 流式输出的增量解析器。
///
/// 接收累积文本，通过偏移量追踪只解析新增部分。
/// 值类型，无并发依赖，可在任意线程使用。

import Foundation

/// ACPStreamParser：
/// 将累积的 ACP 流式输出文本增量解析为 AgentStreamEvent。
/// **累积文本模式**：每次调用 `parse(newText:)` 传入完整的累积输出（包含之前所有内容），
/// 解析器通过 `parsedOffset` 只处理新增部分，确保每个字符只被 split 一次（O(N) 总复杂度）。
nonisolated struct ACPStreamParser: Sendable {
    /// 已解析的字符数偏移量（指向最后一个完整行结尾之后）。
    /// 不完整行不会推进偏移量，下次调用时会从该位置重新读取。
    private var parsedOffset: Int = 0

    /// 解析累积文本中的新增部分，返回本次新解析出的事件。
    /// - Parameter newText: 累积的完整输出文本（每次传入包含之前所有内容）。
    /// - Returns: 本次新解析出的 AgentStreamEvent 数组。
    mutating func parse(newText: String) -> [AgentStreamEvent] {
        guard newText.count > parsedOffset else { return [] }

        let startIdx = newText.index(newText.startIndex, offsetBy: parsedOffset)
        let tail = String(newText[startIdx...])

        var events: [AgentStreamEvent] = []
        let segments = tail.components(separatedBy: "\n")

        // components(separatedBy:) 对 "a\nb\n" 返回 ["a","b",""]，
        // 对 "a\nb" 返回 ["a","b"]。
        // dropLast(1) 在两种情况下都正确：
        //   - tail 以 \n 结尾：去掉末尾空串，保留所有完整行
        //   - tail 不以 \n 结尾：去掉末尾不完整片段，只处理完整行
        let linesToProcess = segments.dropLast(1)

        // 逐行尝试解码 ACP 事件，非 ACP 行自动被 decodeFromStreamLine 过滤
        for line in linesToProcess {
            if let event = AgentStreamEvent.decodeFromStreamLine(line) {
                events.append(event)
            }
        }

        // 只推进到最后一个完整行结尾，不完整行留待下次调用重新处理
        let isComplete = tail.hasSuffix("\n")
        if isComplete {
            parsedOffset = newText.count
        } else {
            // 最后一段是不完整行，不推进偏移量到该部分
            let lastFragment = segments.last ?? ""
            parsedOffset = newText.count - lastFragment.count
        }

        return events
    }

    /// 重置解析状态（新一轮工具调用时调用）。
    mutating func reset() {
        parsedOffset = 0
    }
}
