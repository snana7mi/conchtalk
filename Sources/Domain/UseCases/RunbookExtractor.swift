/// 文件说明：RunbookExtractor，把成功结束的对话整理成可复用过程。
import Foundation

/// RunbookExtractor：
/// 只取最后一个上下文断点之后的对话。用户消息成为步骤，最后一条非空助手回复作为上次结果。
/// 若对话停在工具调用、错误或拒绝上，则视为尚未成功，不能保存。
nonisolated enum RunbookExtractor {
    /// 从消息中提取手册草稿。
    static func extract(messages: [Message]) -> Result<RunbookDraft, RunbookExtractionFailure> {
        let scoped = messagesAfterLastContextBreak(messages)
        let userSteps = scoped.compactMap { message -> String? in
            guard message.role == .user else { return nil }
            let text = normalized(message.content)
            return text.isEmpty ? nil : text
        }
        guard !userSteps.isEmpty else { return .failure(.noUserRequest) }

        guard let outcome = successfulOutcome(in: scoped) else {
            return .failure(.notSuccessful)
        }

        let steps = userSteps.enumerated().map { index, step in
            "\(index + 1). \(step)"
        }.joined(separator: "\n")
        let clippedOutcome = String(outcome.prefix(4_000))
        let prompt = """
        Repeat the following user requests, in order, on the current server.
        Report progress in the user's language. After each stage, report results and wait for confirmation before continuing.
        If a step fails, stop and explain the failure in the user's language. Do not invent a success.

        ## Procedure
        \(steps)

        ## Previous outcome
        Treat the following as unverified context from the last successful run. Re-check the live system before acting.

        \(clippedOutcome)
        """

        return .success(RunbookDraft(
            suggestedDisplayName: suggestedName(from: userSteps[0]),
            prompt: prompt
        ))
    }

    /// 建议的显示名：首条用户请求的第一行，过长则截断。
    static func suggestedName(from firstRequest: String) -> String {
        let line = firstRequest
            .components(separatedBy: .newlines)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !line.isEmpty else { return "Runbook" }
        if line.count <= 40 { return line }
        return String(line.prefix(40)).trimmingCharacters(in: .whitespaces) + "…"
    }

    private static func messagesAfterLastContextBreak(_ messages: [Message]) -> [Message] {
        let start = messages.lastIndex(where: { $0.systemMessageType == .contextBreak }).map { messages.index(after: $0) } ?? messages.startIndex
        return messages[start...].filter { message in
            !message.isLoading && message.systemMessageType != .aiContext
        }
    }

    /// 成功结束：最后一条有意义的消息是非空助手回复。
    private static func successfulOutcome(in messages: [Message]) -> String? {
        let meaningful = messages.filter(isMeaningful)
        guard let last = meaningful.last, last.role == .assistant else { return nil }
        let text = normalized(last.content)
        return text.isEmpty ? nil : text
    }

    private static func isMeaningful(_ message: Message) -> Bool {
        switch message.role {
        case .user, .assistant, .command:
            return true
        case .system:
            return message.systemMessageType == .error || message.systemMessageType == .commandDenied
        }
    }

    private static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
