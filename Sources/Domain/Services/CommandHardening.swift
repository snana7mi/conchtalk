/// 文件说明：CommandHardening，共享的命令安全谓词（禁止/写注入/分段/白名单），供工具与审批策略复用。
import Foundation

/// CommandHardening：
/// 把命令的高危判定、写/注入判定、分段、白名单首词判定集中一处，
/// 供 ExecuteSSHCommandTool 与 ApprovalMatching 共用，确保「始终允许」规则
/// 绝不绕过 hardening（命中 > / tee / heredoc / -exec / 命令替换即否决）。
nonisolated enum CommandHardening {
    /// 明确禁止执行的高危命令模式。
    static let forbiddenPatterns: [String] = [
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
    static let safeCommands: [String] = [
        "ls", "ll", "la", "cat", "head", "tail",
        "pwd", "whoami", "id", "hostname", "uname", "ps",
        "df", "du", "free", "uptime", "date", "cal",
        "echo", "printf", "grep", "find", "locate", "which", "whereis",
        "wc", "sort", "uniq", "cut", "tr", "file", "stat",
        "ip", "ifconfig", "netstat", "ss",
        "ping", "traceroute", "dig", "nslookup", "host",
        "env", "printenv",
        "docker ps", "docker images", "docker logs",
        "git status", "git log", "git diff", "git branch",
        "systemctl status", "journalctl",
    ]

    private static let dangerousRedirectPattern = #">{1,2}\s*/(?:etc|usr|var|boot|sys|proc|dev|sbin|root)/"#
    private static let dangerousExecPattern = #"-exec\s+"#

    /// 是否命中禁止高危模式（全文扫描）。
    static func isForbidden(_ cmd: String) -> Bool {
        for pattern in forbiddenPatterns {
            if let regex = try? Regex(pattern), cmd.contains(regex) { return true }
        }
        return false
    }

    /// 是否包含写重定向 / tee / heredoc / -exec / 命令替换等需强制确认的结构。
    /// 合并了原 containsDangerousPattern 与 containsWriteOrInjection 的全部逻辑。
    static func hasInjectionOrRedirection(_ cmd: String) -> Bool {
        if let regex = try? Regex(dangerousRedirectPattern), cmd.contains(regex) { return true }
        if let regex = try? Regex(dangerousExecPattern), cmd.contains(regex) { return true }
        if cmd.contains("$(") || cmd.contains("`") || cmd.contains("<(") || cmd.contains(">(") { return true }
        if cmd.contains("<<") { return true }
        if cmd.contains(">") { return true }
        if let regex = try? Regex(#"(^|[\s;|&])tee(\s|$)"#), cmd.contains(regex) { return true }
        return false
    }

    /// 将命令按 shell 操作符（`&` `;` `|`）及换行分割为原始段。
    static func splitRawSegments(_ cmd: String) -> [String] {
        cmd.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: CharacterSet(charactersIn: "&;|\n\r"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// 段内按空白切分为 token（用于 argv 前缀匹配）。
    static func tokenize(_ segment: String) -> [String] {
        segment.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
    }

    /// 检查命令是否以安全命令开头（全词匹配）。
    static func matchesSafeCommand(_ cmd: String) -> Bool {
        safeCommands.contains { safe in
            guard cmd.hasPrefix(safe) else { return false }
            if cmd.count == safe.count { return true }
            let nextIndex = cmd.index(cmd.startIndex, offsetBy: safe.count)
            let next = cmd[nextIndex]
            return next == " " || next == "|" || next == ";" || next == "\t" || next == "&"
        }
    }
}
