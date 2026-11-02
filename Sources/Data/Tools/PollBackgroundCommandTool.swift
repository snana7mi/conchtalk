/// 文件说明：PollBackgroundCommandTool，查看后台命令的存活状态并返回日志尾部。
import Foundation

/// PollBackgroundCommandTool：
/// 只读取 `/tmp/conchtalk-bg/` 下由 execute_ssh_command 后台模式创建的日志。
/// 不另起 iOS 后台任务；agent 任务仍在跑时，现有 Live Activity 会显示这次调用的说明。
nonisolated struct PollBackgroundCommandTool: ToolProtocol, @unchecked Sendable {
    let name = "poll_background_command"
    let description = """
        Poll a command started with execute_ssh_command background=true. \
        Pass the log_path (and pid when you have it) from that result. \
        Returns whether the pid is still running and the tail of the log. \
        This does not start a new iOS background task. While the agent task is still in flight, \
        the existing Live Activity shows this step from the explanation.
        """

    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "log_path": [
                "type": "string",
                "description": "Log file path returned when the background command started. Must be under /tmp/conchtalk-bg/.",
            ] as [String: String],
            "pid": [
                "type": "string",
                "description": "Optional numeric pid returned when the background command started.",
            ] as [String: String],
            "tail_lines": [
                "type": "integer",
                "description": "How many log lines to return, from 1 to 200. Defaults to 80.",
            ] as [String: Any],
            "explanation": [
                "type": "string",
                "description": "A brief explanation of why you are polling, in the user's language",
            ] as [String: String],
        ] as [String: Any],
        "required": ["log_path", "explanation"],
    ]

    /// 只读托管日志，默认可自动执行。敏感路径仍要确认。
    func validateSafety(arguments: [String: Any]) -> SafetyLevel {
        let path = arguments["log_path"] as? String ?? ""
        if ReadFilePolicy.isSensitivePath(path) { return .needsConfirmation }
        return .safe
    }

    /// 读取日志尾部并报告进程状态。
    func execute(arguments: [String: Any], sshClient: SSHClientProtocol) async throws -> ToolExecutionResult {
        guard let rawPath = arguments["log_path"] as? String else {
            throw ToolError.missingParameter("log_path")
        }
        let logPath = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard BackgroundCommandLauncher.isManagedLogPath(logPath) else {
            throw ToolError.invalidArguments("log_path must be a file under \(BackgroundCommandLauncher.directory)/")
        }
        let pid = (arguments["pid"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let pid, !pid.isEmpty, pid.range(of: #"^\d+$"#, options: .regularExpression) == nil {
            throw ToolError.invalidArguments("pid must be numeric")
        }
        let lines = BackgroundCommandLauncher.clampTailLines(
            ToolArguments.int(arguments["tail_lines"]) ?? BackgroundCommandLauncher.defaultTailLines
        )
        let command = BackgroundCommandLauncher.pollScript(
            logPath: logPath,
            pid: (pid?.isEmpty == false) ? pid : nil,
            tailLines: lines
        )
        let output = try await sshClient.execute(command: command, timeout: 30, reclaimOnTimeout: true)
        return ToolExecutionResult(output: output)
    }
}
