import Foundation

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

    private static let forbiddenPatterns: [String] = [
        #"rm\s+-rf\s+/"#,
        #"rm\s+-fr\s+/"#,
        #"mkfs\b"#,
        #"dd\s+if=/dev/(zero|random|urandom)"#,
        #":\(\)\s*\{\s*:\|:\s*&\s*\}"#,
        #">\s*/dev/sd[a-z]"#,
        #"chmod\s+-R\s+777\s+/"#,
        #"chown\s+-R\s+.*\s+/$"#,
        #"wget.*\|\s*sh"#,
        #"curl.*\|\s*sh"#,
        #"curl.*\|\s*bash"#,
    ]

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

    func execute(arguments: [String: Any], sshClient: SSHClientProtocol) async throws -> ToolExecutionResult {
        guard let command = arguments["command"] as? String else {
            throw ToolError.missingParameter("command")
        }
        let output = try await sshClient.execute(command: command)
        return ToolExecutionResult(output: output)
    }

    private func extractBaseCommand(_ cmd: String) -> String {
        let lastCommand = cmd.components(separatedBy: "&&").last?.trimmingCharacters(in: .whitespaces) ?? cmd
        return lastCommand.components(separatedBy: .whitespaces).first ?? cmd
    }
}
