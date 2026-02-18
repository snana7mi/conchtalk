import Foundation

struct CommandSafetyValidator: CommandSafetyValidating, Sendable {

    // Forbidden patterns - never allow these
    private static let forbiddenPatterns: [String] = [
        #"rm\s+-rf\s+/"#,
        #"rm\s+-fr\s+/"#,
        #"mkfs\b"#,
        #"dd\s+if=/dev/(zero|random|urandom)"#,
        #":\(\)\s*\{\s*:\|:\s*&\s*\}"#,     // fork bomb
        #">\s*/dev/sd[a-z]"#,
        #"chmod\s+-R\s+777\s+/"#,
        #"chown\s+-R\s+.*\s+/$"#,
        #"wget.*\|\s*sh"#,
        #"curl.*\|\s*sh"#,
        #"curl.*\|\s*bash"#,
    ]

    // Safe command prefixes - auto-execute these
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

    func validate(_ command: SSHCommand) -> CommandSafetyLevel {
        let cmd = command.command.trimmingCharacters(in: .whitespacesAndNewlines)

        // Check forbidden patterns first
        for pattern in Self.forbiddenPatterns {
            if let regex = try? Regex(pattern), cmd.contains(regex) {
                return .forbidden
            }
        }

        // Check if it's a safe read-only command
        let baseCommand = extractBaseCommand(cmd)
        if Self.safeCommands.contains(where: { cmd.hasPrefix($0) || baseCommand == $0 }) {
            // Double check: even "safe" commands can be piped to destructive ones
            if cmd.contains("|") {
                let pipeTarget = cmd.components(separatedBy: "|").last?.trimmingCharacters(in: .whitespaces) ?? ""
                let pipeBase = extractBaseCommand(pipeTarget)
                if ["rm", "dd", "mkfs", "sh", "bash"].contains(pipeBase) {
                    return .needsConfirmation
                }
            }
            // Also trust LLM's is_destructive flag for safe commands
            if !command.isDestructive {
                return .safe
            }
        }

        // Everything else needs confirmation
        return .needsConfirmation
    }

    private func extractBaseCommand(_ cmd: String) -> String {
        // Handle commands like "cd /app && git status" - get the last command after &&
        let lastCommand = cmd.components(separatedBy: "&&").last?.trimmingCharacters(in: .whitespaces) ?? cmd
        // Get first word
        return lastCommand.components(separatedBy: .whitespaces).first ?? cmd
    }
}
