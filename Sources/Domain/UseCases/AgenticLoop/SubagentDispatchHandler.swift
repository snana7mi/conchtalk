/// 文件说明：SubagentDispatchHandler，拦截 dispatch_subagent：解析任务、调 Runner、生成卡片与回填文本。
import Foundation

/// SubagentDispatchHandler：
/// 把 dispatch_subagent 的参数解析为 [SubagentTask]，调用 SubagentRunning，
/// 把每个结果转成一条 UI 卡片消息，并汇总为回填给主模型的 tool result 文本。
/// - Note: 与 SpecialToolHandler 同属主循环的「特殊工具拦截」层，纯函数式、无副作用，
///   消息追加 / 回调由 ExecuteNaturalLanguageCommandUseCase 主循环负责。
nonisolated enum SubagentDispatchHandler {

    /// DispatchOutput：
    /// 拦截处理的产物：要回填到会话的卡片消息，及汇总给主模型的 tool result 文本。
    struct DispatchOutput: Sendable {
        /// 每个 subagent 结果对应一条 UI 卡片消息（成功落结论、失败落错误文案）。
        /// 不携带原 dispatch toolCall，避免模型历史产生重复 tool_call_id。
        let messages: [Message]
        /// 回填给主模型的汇总文本（任务 + 结论 / 失败原因）。
        let output: String
    }

    /// 处理 dispatch_subagent 工具调用。
    /// - Parameters:
    ///   - toolCall: AI 发起的 dispatch_subagent 调用（参数含 tasks 数组）。
    ///   - reasoning: 本轮推理文本，挂到生成的卡片消息上。
    ///   - runner: 子 agent 编排器，执行解析出的任务。
    /// - Returns: 卡片消息与汇总输出；tasks 为空时返回空消息 + 以 "ERROR" 开头的提示。
    static func handle(
        toolCall: ToolCall,
        reasoning: String?,
        runner: SubagentRunning
    ) async -> DispatchOutput {
        let tasks = parseTasks(toolCall)
        guard !tasks.isEmpty else {
            return DispatchOutput(
                messages: [],
                output: "ERROR: dispatch_subagent requires a non-empty 'tasks' array of { subagent_type, prompt }."
            )
        }

        let results = await runner.run(tasks: tasks)

        var messages: [Message] = []
        var blocks: [String] = []
        for result in results {
            // 卡片正文：成功落子 agent 结论，失败落精炼错误文案。
            let body = result.succeeded ? result.outcome : "失败: \(result.errorSummary ?? "unknown error")"
            let card = Message(
                role: .command,
                content: "subagent: \(result.subagentName)",
                toolOutput: body,
                reasoningContent: reasoning
            )
            messages.append(card)
            if result.succeeded {
                blocks.append("[subagent: \(result.subagentName)] 任务: \(result.task)\n结论:\n\(result.outcome)")
            } else {
                blocks.append("[subagent: \(result.subagentName)] 任务: \(result.task)\n失败: \(result.errorSummary ?? "unknown error")")
            }
        }
        return DispatchOutput(messages: messages, output: blocks.joined(separator: "\n\n"))
    }

    /// 从工具参数解析出 [SubagentTask]；解码失败或字段缺失的条目被丢弃。
    private static func parseTasks(_ toolCall: ToolCall) -> [SubagentTask] {
        guard let args = try? toolCall.decodedArguments(),
              let raw = args["tasks"] as? [[String: Any]] else {
            return []
        }
        return raw.compactMap { dict in
            guard let type = dict["subagent_type"] as? String, !type.isEmpty,
                  let prompt = dict["prompt"] as? String, !prompt.isEmpty else {
                return nil
            }
            return SubagentTask(subagentType: type, prompt: prompt)
        }
    }
}
