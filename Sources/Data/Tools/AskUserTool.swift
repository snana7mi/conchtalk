/// 文件说明：AskUserTool，让 AI 以结构化问题（可点选项 + 自由输入兜底）向用户澄清，在 agentic loop 中被拦截并结束本轮。
import Foundation

/// AskUserTool：
/// AI 需要用户做决定或补充信息时调用。agentic loop 拦截后把问题渲染为卡片并结束本轮，
/// 用户点选项（或直接在输入框输入）即作为下一条用户消息发送，模型在下一轮读到答案。
/// 没有远端副作用，不经过审批。
nonisolated struct AskUserTool: ToolProtocol, @unchecked Sendable {
    static let toolName = "ask_user"
    let name = AskUserTool.toolName
    let description = """
        Ask the user a clarifying question when you cannot proceed safely without their decision \
        (e.g. which of several services/paths/versions they mean, or whether to take a risky option). \
        Provide 2-5 short, mutually exclusive options when possible; the user can also type a free-form answer. \
        This ends your current turn: do not call other tools in the same response, and wait for the answer in the next user message. \
        Do not use it for confirmations of tool calls (the app already asks for approval) or for questions you can answer by inspecting the server.
        """

    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "question": [
                "type": "string",
                "description": "The question, in the user's language. One or two sentences.",
            ] as [String: String],
            "options": [
                "type": "array",
                "items": ["type": "string"] as [String: String],
                "description": "2-5 short answer options (under 8 words each), in the user's language. Omit for open questions.",
            ] as [String: Any],
        ] as [String: Any],
        "required": ["question"],
    ]

    func validateSafety(arguments: [String: Any]) -> SafetyLevel { .safe }

    /// 通常在 agentic loop 中被拦截；直接执行（无交互上下文）时告诉模型改为在回复中提问。
    func execute(arguments: [String: Any], sshClient: SSHClientProtocol) async throws -> ToolExecutionResult {
        ToolExecutionResult(
            output: "ERROR: ask_user is not available in this context. Put the question in your final answer instead.",
            isSuccess: false
        )
    }
}

/// UserQuestion：ask_user 参数的解析结果。
nonisolated struct UserQuestion: Equatable, Sendable {
    static let maxOptions = 6
    static let maxOptionLength = 120

    let question: String
    let options: [String]

    /// 回填给模型的工具结果（英文，模型可见）。
    var modelAcknowledgement: String {
        let optionText = options.isEmpty ? "" : " with options: " + options.map { "\"\($0)\"" }.joined(separator: ", ")
        return "The question was shown to the user\(optionText). Your turn has ended; the user's answer will arrive as their next message."
    }

    static func parse(_ arguments: [String: Any]) -> UserQuestion? {
        guard let question = (arguments["question"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !question.isEmpty else { return nil }
        var seen = Set<String>()
        let options = ((arguments["options"] as? [Any]) ?? [])
            .compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.count <= maxOptionLength && seen.insert($0).inserted }
        return UserQuestion(question: question, options: Array(options.prefix(maxOptions)))
    }

    /// 从已持久化的工具调用还原问题（UI 渲染用）。
    static func from(toolCall: ToolCall) -> UserQuestion? {
        guard toolCall.toolName == AskUserTool.toolName,
              let args = try? toolCall.decodedArguments() else { return nil }
        return parse(args)
    }
}
