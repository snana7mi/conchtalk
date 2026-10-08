/// 文件说明：UpdatePlanTool，让 AI 在多步任务中维护可见的执行计划（待办清单），在 agentic loop 中被拦截并渲染为计划卡片。
import Foundation

/// UpdatePlanTool：
/// 每次调用提交完整计划（覆盖上一版），状态为 pending / in_progress / completed。
/// 没有远端副作用：在 agentic loop 中被拦截，不经过审批（严格模式下也不弹窗），
/// 并以与直连模式 ACP plan 相同的清单样式展示。
nonisolated struct UpdatePlanTool: ToolProtocol, @unchecked Sendable {
    static let toolName = "update_plan"
    let name = UpdatePlanTool.toolName
    let description = """
        Create or update a short, visible plan (todo list) for the current task. \
        Use it for tasks that need 3 or more distinct steps (e.g. diagnosing a service, multi-file changes, installs); \
        skip it for simple questions or single commands. \
        Each call replaces the whole plan. Keep steps short (under 10 words), keep exactly one step 'in_progress' while working, \
        and mark steps 'completed' as soon as they are done. Update the plan when it changes; do not repeat an unchanged plan.
        """

    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "plan": [
                "type": "array",
                "description": "The complete list of steps, in order.",
                "items": [
                    "type": "object",
                    "properties": [
                        "step": ["type": "string", "description": "Short description of the step, in the user's language."] as [String: String],
                        "status": ["type": "string", "enum": ["pending", "in_progress", "completed"]] as [String: Any],
                    ] as [String: Any],
                    "required": ["step", "status"],
                ] as [String: Any],
            ] as [String: Any],
            "explanation": [
                "type": "string",
                "description": "Optional one-line note about what changed in the plan, in the user's language.",
            ] as [String: String],
        ] as [String: Any],
        "required": ["plan"],
    ]

    func validateSafety(arguments: [String: Any]) -> SafetyLevel { .safe }

    /// 通常在 agentic loop 中被拦截；直接执行时只做校验并返回同样的结果。
    func execute(arguments: [String: Any], sshClient: SSHClientProtocol) async throws -> ToolExecutionResult {
        switch AgentPlanUpdate.parse(arguments) {
        case .success(let update):
            return ToolExecutionResult(output: update.modelAcknowledgement)
        case .failure(let error):
            return ToolExecutionResult(output: "ERROR: \(error.message)", isSuccess: false)
        }
    }
}

/// AgentPlanUpdate：update_plan 参数的解析结果。
nonisolated struct AgentPlanUpdate: Equatable, Sendable {
    nonisolated struct ParseError: Error, Equatable {
        let message: String
    }

    static let allowedStatuses: Set<String> = ["pending", "in_progress", "completed"]
    static let maxSteps = 20

    let entries: [AgentPlanEntry]
    let explanation: String?

    var completedCount: Int { entries.filter { $0.status == "completed" }.count }

    /// 回填给模型的确认文本（英文，模型可见）。
    var modelAcknowledgement: String {
        "Plan updated (\(completedCount)/\(entries.count) completed). It is shown to the user; keep it current as you work."
    }

    static func parse(_ arguments: [String: Any]) -> Result<AgentPlanUpdate, ParseError> {
        guard let raw = arguments["plan"] as? [Any], !raw.isEmpty else {
            return .failure(ParseError(message: "'plan' must be a non-empty array of {step, status}."))
        }
        var entries: [AgentPlanEntry] = []
        for item in raw.prefix(maxSteps) {
            guard let dict = item as? [String: Any],
                  let step = (dict["step"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !step.isEmpty else {
                return .failure(ParseError(message: "Each plan item needs a non-empty 'step'."))
            }
            let status = (dict["status"] as? String) ?? "pending"
            guard allowedStatuses.contains(status) else {
                return .failure(ParseError(message: "Invalid status '\(status)'. Use pending, in_progress or completed."))
            }
            entries.append(AgentPlanEntry(title: step, status: status))
        }
        let explanation = (arguments["explanation"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return .success(AgentPlanUpdate(entries: entries, explanation: explanation?.isEmpty == true ? nil : explanation))
    }

    /// 从已持久化的工具调用还原计划（UI 渲染用）。
    static func from(toolCall: ToolCall) -> AgentPlanUpdate? {
        guard toolCall.toolName == UpdatePlanTool.toolName,
              let args = try? toolCall.decodedArguments(),
              case .success(let update) = parse(args) else { return nil }
        return update
    }
}
