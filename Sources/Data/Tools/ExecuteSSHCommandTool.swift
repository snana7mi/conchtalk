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

    /// 明确禁止执行的高危命令模式。
    private static let forbiddenPatterns: [String] = [
        #"rm\s+-rf\s+/"#,
        #"rm\s+-fr\s+/"#,
        #"mkfs"#,
        #"dd\s+if=/dev/(zero|random|urandom)"#,
        #":\(\)\s*\{\s*:\|:\s*&\s*\}"#,
        #">\s*/dev/sd[a-z]"#,
        #"chmod\s+-R\s+777\s+/"#,
        #"chown\s+-R\s+.*\s+/$"#,
    ]

    /// 常见只读/低风险命令白名单（用于自动放行判定）。
    private static let safeCommands: [String] = [
        "ls", "ll", "la",
        "cat", "head", "tail",
        "pwd", "whoami", "id", "hostname", "uname",
        "ps",
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

    /// 检查命令是否以安全命令开头（全词匹配，防止 "find" 匹配 "find / -exec rm"
    /// 等情况——要求命令名后紧跟空格、管道、分号或字符串结束）。
    private static func matchesSafeCommand(_ cmd: String) -> Bool {
        safeCommands.contains { safe in
            guard cmd.hasPrefix(safe) else { return false }
            // 安全命令与输入等长 -> 完全匹配
            if cmd.count == safe.count { return true }
            // 命令名后的下一个字符必须是分隔符，而非普通字母/数字
            let nextIndex = cmd.index(cmd.startIndex, offsetBy: safe.count)
            let next = cmd[nextIndex]
            return next == " " || next == "|" || next == ";" || next == "\t" || next == "&"
        }
    }

    /// 检测命令中是否包含重定向到敏感系统路径（如 > /etc/xxx、>> /var/xxx）
    /// 或包含 -exec 模式（如 find -exec rm），这些场景即使命令本身在白名单也应需要确认。
    private static let dangerousRedirectPattern = #">{1,2}\s*/(?:etc|usr|var|boot|sys|proc|dev|sbin|root)/"#
    private static let dangerousExecPattern = #"-exec\s+"#

    private static func containsDangerousPattern(_ cmd: String) -> Bool {
        if let regex = try? Regex(dangerousRedirectPattern), cmd.contains(regex) {
            return true
        }
        if let regex = try? Regex(dangerousExecPattern), cmd.contains(regex) {
            return true
        }
        // 命令替换 / 进程替换：$(...)、反引号、<(...)、>(...) 会内嵌任意命令，
        // 不会被 splitRawSegments 分段，白名单首词判定无法看穿——一律降级需确认。
        if cmd.contains("$(") || cmd.contains("`") || cmd.contains("<(") || cmd.contains(">(") {
            return true
        }
        return false
    }

    /// 评估命令风险级别并决定是否需要确认。
    /// - Parameter arguments: 工具入参，至少包含 `command` 与 `is_destructive`。
    /// - Returns: 命令安全级别（safe / needsConfirmation / forbidden）。
    /// - Note: 不信任 AI 自报的 `is_destructive`，通过独立检测重定向和 `-exec` 等危险模式做兜底。
    func validateSafety(arguments: [String: Any]) -> SafetyLevel {
        let cmd = (arguments["command"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let isDestructive = arguments["is_destructive"] as? Bool ?? true

        // 禁止高危命令（全文扫描）
        for pattern in Self.forbiddenPatterns {
            if let regex = try? Regex(pattern), cmd.contains(regex) {
                return .forbidden
            }
        }

        // 将命令按 shell 操作符分段（保留 sudo 等前缀，用于安全判定）。
        let rawSegments = Self.splitRawSegments(cmd)

        // 所有段都必须匹配安全白名单，命令链才被视为 safe。
        let allSegmentsSafe = !rawSegments.isEmpty && rawSegments.allSatisfy { segment in
            let firstToken = segment.components(separatedBy: .whitespaces)
                .first { !$0.isEmpty } ?? segment
            return Self.matchesSafeCommand(segment) || Self.safeCommands.contains(firstToken)
        }

        if allSegmentsSafe {
            // 包含重定向到系统路径或 -exec 模式 -> 不信任 is_destructive，强制确认
            if Self.containsDangerousPattern(cmd) {
                return .needsConfirmation
            }
            if !isDestructive {
                return .safe
            }
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

    // MARK: - Command Parsing Helpers

    /// 将命令按 shell 操作符（`&` `;` `|`）及换行分割为原始段（不跳过 sudo 等前缀）。
    /// 用于安全检查——`sudo ls` 不应被视为与 `ls` 同等安全；换行也必须分段，
    /// 否则 `printf x\nrm -rf ~` 会被首词 `printf` 误判为安全。
    private static func splitRawSegments(_ cmd: String) -> [String] {
        cmd.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: CharacterSet(charactersIn: "&;|\n\r"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
