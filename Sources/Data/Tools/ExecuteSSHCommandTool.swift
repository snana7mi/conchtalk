/// 文件说明：ExecuteSSHCommandTool，提供通用远端命令执行能力并内置风险分级。
import Foundation

/// ExecuteSSHCommandTool：
/// 作为兜底型工具执行任意 SSH 命令，并通过模式匹配与白名单策略
/// 对高风险命令做拦截或二次确认。
struct ExecuteSSHCommandTool: ToolProtocol {
    let name = "execute_ssh_command"
    let description = "Execute an SSH command on the remote server. Use this to run commands that help accomplish the user's task."

    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "command": [
                "type": "string",
                "description": "The shell command to execute on the remote server",
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

    /// 明确禁止执行的高危命令模式。
    private static let forbiddenPatterns: [String] = [
        #"rm\s+-rf\s+/"#,
        #"rm\s+-fr\s+/"#,
        #"mkfs\b"#,
        #"dd\s+if=/dev/(zero|random|urandom)"#,
        #":\(\)\s*\{\s*:\|:\s*&\s*\}"#,
        #">\s*/dev/sd[a-z]"#,
        #"chmod\s+-R\s+777\s+/"#,
        #"chown\s+-R\s+.*\s+/$"#,
    ]

    /// 常见只读/低风险命令白名单（用于自动放行判定）。
    private static let safeCommands: [String] = [
        "ls", "ll", "la",
        "cat", "head", "tail", "less", "more",
        "pwd", "whoami", "id", "hostname", "uname",
        "ps", "top", "htop",
        "df", "du", "free",
        "uptime", "date", "cal",
        "echo", "printf",
        "grep", "find", "locate", "which", "whereis",
        "wc", "sort", "uniq", "cut", "tr",
        "file", "stat",
        "ip", "ifconfig", "netstat", "ss",
        "ping", "traceroute", "dig", "nslookup", "host",
        "env", "printenv",
        "docker ps", "docker images", "docker logs",
        "git status", "git log", "git diff", "git branch",
        "systemctl status",
        "journalctl",
    ]

    /// 评估命令风险级别并决定是否需要确认。
    /// - Parameter arguments: 工具入参，至少包含 `command` 与 `is_destructive`。
    /// - Returns: 命令安全级别（safe / needsConfirmation / forbidden）。
    /// - Note: 对命令管道会额外检查末端命令是否存在危险落点（如 `| sh`）。
    func validateSafety(arguments: [String: Any]) -> SafetyLevel {
        let cmd = (arguments["command"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let isDestructive = arguments["is_destructive"] as? Bool ?? true

        for pattern in Self.forbiddenPatterns {
            if let regex = try? Regex(pattern), cmd.contains(regex) {
                return .forbidden
            }
        }

        let baseCommand = extractBaseCommand(cmd)
        if Self.safeCommands.contains(where: { cmd.hasPrefix($0) || baseCommand == $0 }) {
            if cmd.contains("|") {
                let pipeTarget = cmd.components(separatedBy: "|").last?.trimmingCharacters(in: .whitespaces) ?? ""
                let pipeBase = extractBaseCommand(pipeTarget)
                if ["rm", "dd", "mkfs", "sh", "bash"].contains(pipeBase) {
                    return .needsConfirmation
                }
            }
            if !isDestructive {
                return .safe
            }
        }

        return .needsConfirmation
    }

    var supportsStreaming: Bool { true }

    /// 在远端执行命令并返回标准化输出。
    /// - Parameters:
    ///   - arguments: 工具入参，需包含 `command`。
    ///   - sshClient: SSH 执行客户端。
    /// - Returns: 命令标准输出/错误输出的聚合文本。
    /// - Throws: 缺少命令参数或远端执行失败时抛出。
    func execute(arguments: [String: Any], sshClient: SSHClientProtocol) async throws -> ToolExecutionResult {
        guard let command = arguments["command"] as? String else {
            throw ToolError.missingParameter("command")
        }
        let output = try await sshClient.execute(command: command)
        return ToolExecutionResult(output: output)
    }

    /// 以流式方式在远端执行命令，逐块返回输出。
    /// 仅对需确认的命令（写操作/长耗时）启用流式；安全的只读短命令返回 `nil` 走缓冲模式，
    /// 避免流式通道建立开销和 UI 逐块刷新。
    func executeStreaming(arguments: [String: Any], sshClient: SSHClientProtocol) async throws -> AsyncThrowingStream<String, Error>? {
        guard let command = arguments["command"] as? String else {
            throw ToolError.missingParameter("command")
        }
        // 安全命令走缓冲模式
        if validateSafety(arguments: arguments) == .safe {
            return nil
        }
        return sshClient.executeStreaming(command: command)
    }

    /// 提取复合命令中的基准命令词（用于安全判定）。
    /// - Parameter cmd: 原始命令字符串。
    /// - Returns: 末段命令的首个 token（如 `sudo systemctl restart nginx` -> `sudo`）。
    private func extractBaseCommand(_ cmd: String) -> String {
        let lastCommand = cmd.components(separatedBy: "&&").last?.trimmingCharacters(in: .whitespaces) ?? cmd
        return lastCommand.components(separatedBy: .whitespaces).first ?? cmd
    }
}
