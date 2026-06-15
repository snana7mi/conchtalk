/// 文件说明：ExecuteSSHCommandTool，提供通用远端命令执行能力并内置风险分级。
import Foundation

/// ExecuteSSHCommandTool：
/// 作为通用工具执行任意 SSH 命令，通过模式匹配与白名单策略
/// 对高风险命令做拦截或二次确认。
nonisolated struct ExecuteSSHCommandTool: ToolProtocol, @unchecked Sendable {
    let name = "execute_ssh_command"
    let description = """
        Execute a shell command on the remote server. \
        For file operations, prefer specialized tools: \
        read_file for reading, write_file for writing, edit_file for editing, \
        grep/glob for searching. \
        Set is_destructive to true for write/modify/delete/restart operations, \
        false for read-only commands (ls, cat, ps, df, etc.).
        """

    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "command": [
                "type": "string",
                "description": "The shell command to execute on the remote server.",
            ] as [String: String],
            "explanation": [
                "type": "string",
                "description": "A brief explanation of what this command does, in the user's language",
            ] as [String: String],
            "is_destructive": [
                "type": "boolean",
                "description": "Whether this command modifies server state (write/delete/restart operations). Read-only commands like ls, cat, ps should be false.",
            ] as [String: String],
        ] as [String: [String: String]],
        "required": ["command", "explanation", "is_destructive"],
    ]

    // MARK: - Safety Validation

    /// 评估命令风险级别并决定是否需要确认。
    /// - Parameter arguments: 工具入参，至少包含 `command` 与 `is_destructive`。
    /// - Returns: 命令安全级别（safe / needsConfirmation / forbidden）。
    /// - Note: 不信任 AI 自报的 `is_destructive`，通过 CommandHardening 共享谓词
    ///   独立检测重定向和 `-exec` 等危险模式做兜底。
    func validateSafety(arguments: [String: Any]) -> SafetyLevel {
        let cmd = (arguments["command"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let isDestructive = arguments["is_destructive"] as? Bool ?? true

        if CommandHardening.isForbidden(cmd) { return .forbidden }

        let rawSegments = CommandHardening.splitRawSegments(cmd)
        let allSegmentsSafe = !rawSegments.isEmpty && rawSegments.allSatisfy { segment in
            let firstToken = CommandHardening.tokenize(segment).first ?? segment
            return CommandHardening.matchesSafeCommand(segment) || CommandHardening.safeCommands.contains(firstToken)
        }
        if allSegmentsSafe {
            if CommandHardening.hasInjectionOrRedirection(cmd) { return .needsConfirmation }
            if !isDestructive { return .safe }
        }
        return .needsConfirmation
    }

    var supportsStreaming: Bool { false }

    /// 在远端执行命令并返回标准化输出。
    func execute(arguments: [String: Any], sshClient: SSHClientProtocol) async throws -> ToolExecutionResult {
        guard let command = arguments["command"] as? String else {
            throw ToolError.missingParameter("command")
        }
        let output = try await sshClient.execute(command: command)
        return ToolExecutionResult(output: output)
    }
}
