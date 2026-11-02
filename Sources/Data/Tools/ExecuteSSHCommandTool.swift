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
        false for read-only commands (ls, cat, ps, df, etc.). \
        Optional timeout is seconds, clamped to 1...600 (default 30). On timeout the remote process group is killed and the SSH connection stays up. \
        Set background to true for a long-running command: it is started with nohup, output goes to a log file, and the call returns immediately. \
        Then use poll_background_command to tail that log. While this agent task is still running, the existing Live Activity shows the current step.
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
            "timeout": [
                "type": "integer",
                "description": "Optional timeout in seconds, clamped to 1...600. Defaults to 30. Ignored when background is true.",
                "minimum": 1,
                "maximum": 600,
            ] as [String: Any],
            "background": [
                "type": "boolean",
                "description": "If true, detach the command with nohup, write stdout and stderr to a log file, and return the pid and log path immediately. Use poll_background_command to tail the log.",
            ] as [String: String],
        ] as [String: Any],
        "required": ["command", "explanation", "is_destructive"],
    ]

    // MARK: - Safety Validation

    /// 评估命令风险级别并决定是否需要确认。
    /// - Parameter arguments: 工具入参，至少包含 `command` 与 `is_destructive`。
    /// - Returns: 命令安全级别（safe / needsConfirmation / forbidden）。
    /// - Note: 不信任 AI 自报的 `is_destructive`，通过 CommandHardening 共享谓词
    ///   独立检测重定向和 `-exec` 等危险模式做兜底。
    func validateSafety(arguments: [String: Any]) -> SafetyLevel {
        let level = commandSafety(arguments: arguments)
        // 后台模式会留下进程和日志文件，只读命令也要确认。
        if ToolArguments.bool(arguments["background"]), level == .safe {
            return .needsConfirmation
        }
        return level
    }

    /// 按命令文本分级，不看 background。
    private func commandSafety(arguments: [String: Any]) -> SafetyLevel {
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
    /// 前台命令使用有上界的超时，超时只结束远端进程组。后台命令立刻返回日志路径。
    func execute(arguments: [String: Any], sshClient: SSHClientProtocol) async throws -> ToolExecutionResult {
        guard let command = arguments["command"] as? String else {
            throw ToolError.missingParameter("command")
        }
        if ToolArguments.bool(arguments["background"]) {
            let paths = BackgroundCommandLauncher.paths()
            let script = BackgroundCommandLauncher.launchScript(
                command: command,
                logPath: paths.log,
                pidPath: paths.pid
            )
            let output = try await sshClient.execute(command: script, timeout: 20, reclaimOnTimeout: false)
            return ToolExecutionResult(output: """
                Background command started.
                log_path: \(paths.log)
                pid_file: \(paths.pid)
                \(output)
                Use poll_background_command with log_path and pid to tail the log. \
                The process is detached with nohup, so it keeps running after this call returns. \
                While you poll, the in-flight agent task continues to show this step on the existing Live Activity.
                """)
        }

        let requested = ToolArguments.timeInterval(arguments["timeout"]) ?? RemoteCommandSupervisor.defaultTimeout
        let timeout = RemoteCommandSupervisor.clamp(requested)
        let output = try await sshClient.execute(command: command, timeout: timeout, reclaimOnTimeout: true)
        return ToolExecutionResult(output: output)
    }
}
