/// 文件说明：DispatchSubagentTool，声明 dispatch_subagent 工具元信息；执行体由主循环拦截。
import Foundation

/// DispatchSubagentTool：
/// 仅提供 name/description/schema/安全级别。真正的子 agent 编排在
/// ExecuteNaturalLanguageCommandUseCase 中拦截（需要 aiService，普通 Tool 拿不到）。
nonisolated struct DispatchSubagentTool: ToolProtocol, @unchecked Sendable {
    /// 可用角色摘要（name: description），注入 description 供模型选型。
    private let subagentSummaries: String

    init(subagentSummaries: String) {
        self.subagentSummaries = subagentSummaries
    }

    /// 工具名常量。供主循环拦截分支与 SubagentRunner 嵌套防护引用，避免字符串硬编码重复。
    static let toolName = "dispatch_subagent"

    let name = DispatchSubagentTool.toolName

    var description: String {
        """
        Dispatch one or more independent subtasks to specialized subagents that run with \
        their own isolated context and return only a concise final result. Use this to keep \
        large intermediate output (file reads, command output) out of the main conversation, \
        to parallelize independent subtasks, or to delegate to a specialized role. \
        Each task: { subagent_type, prompt }. Subagents cannot dispatch further subagents.
        Available subagents:
        \(subagentSummaries)
        """
    }

    var parametersSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "tasks": [
                    "type": "array",
                    "description": "One or more subagent tasks to run (multiple = parallel).",
                    "items": [
                        "type": "object",
                        "properties": [
                            "subagent_type": [
                                "type": "string",
                                "description": "Name of the subagent role to use."
                            ],
                            "prompt": [
                                "type": "string",
                                "description": "Self-contained task description for the subagent."
                            ]
                        ],
                        "required": ["subagent_type", "prompt"]
                    ] as [String: Any]
                ] as [String: Any]
            ] as [String: Any],
            "required": ["tasks"]
        ]
    }

    func validateSafety(arguments: [String: Any]) -> SafetyLevel { .safe }

    func execute(arguments: [String: Any], sshClient: SSHClientProtocol) async throws -> ToolExecutionResult {
        // 正常情况下不会走到这里（被主循环拦截）。兜底返回提示。
        ToolExecutionResult(output: "dispatch_subagent must be handled by the agent loop interceptor.")
    }
}
