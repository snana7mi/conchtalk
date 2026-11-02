/// 文件说明：CommandHardening，共享的命令安全谓词（禁止/写注入/分段/白名单），供工具与审批策略复用。
import Foundation

/// CommandHardening：
/// 把命令的高危判定、写/注入判定、分段、白名单判定集中一处，
/// 供 ExecuteSSHCommandTool 与 ApprovalMatching 共用，确保「始终允许」规则
/// 绝不绕过 hardening（命中 > / tee / heredoc / -exec / 命令替换即否决）。
/// 自动放行会跳过包装器，并识别白名单命令里的破坏性子命令与标志。
nonisolated enum CommandHardening {
    /// 明确禁止执行的高危命令模式。
    /// `rm` 与 `mkfs` 不在这里：前者要按标志和目标解析，后者要词边界，见 `isForbidden`。
    static let forbiddenPatterns: [String] = [
        #"dd\s+if=/dev/(zero|random|urandom)"#,
        #":\(\)\s*\{\s*:\|:\s*&\s*\}"#,
        #">\s*/dev/sd[a-z]"#,
        #"chmod\s+-R\s+777\s+/"#,
        #"chown\s+-R\s+.*\s+/$"#,
    ]

    /// 常见只读/低风险命令白名单（用于自动放行判定）。
    /// 其中 `env`、`find`、`ip`、`hostname`、`date` 以及多词条目还要再看参数，不能只认首词。
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

    /// 会把后续参数当成新命令执行的包装器。带上子命令后一律不自动放行。
    /// `env` 单独处理：没有子命令时只是打印环境变量。
    private static let blockingWrappers: Set<String> = [
        "sudo", "doas", "nohup", "xargs", "timeout", "nice", "time",
        "command", "exec", "eval", "setsid", "ionice", "stdbuf",
        "flock", "watch", "chrt", "taskset", "busybox",
        "sh", "bash", "dash", "zsh", "ksh", "ash",
    ]

    private static let flagAwareCommands: Set<String> = ["hostname", "date", "find", "ip"]

    private static let simpleReadOnlyCommands: Set<String> = {
        var names: Set<String> = []
        for entry in safeCommands where !entry.contains(" ") {
            if entry == "env" || flagAwareCommands.contains(entry) { continue }
            names.insert(entry)
        }
        return names
    }()

    /// 递归删除这些顶层目录（或其 `/*`）视为清空系统，直接禁止。
    /// 其子路径（如 `/tmp/build`、`/usr/bin`）不在此列，只要求确认。
    private static let protectedTopLevelDirectories: Set<String> = [
        "bin", "boot", "dev", "etc", "home", "lib", "lib32", "lib64", "libx32",
        "lost+found", "media", "mnt", "opt", "proc", "root", "run", "sbin",
        "srv", "sys", "tmp", "usr", "var",
    ]

    private static let findMutatingOptions: Set<String> = [
        "-delete", "-exec", "-execdir", "-ok", "-okdir",
        "-fprint", "-fprint0", "-fprintf", "-fls",
    ]

    private static let hostnameReadOnlyFlags: Set<String> = [
        "-a", "-A", "-d", "-f", "-i", "-I", "-s", "-v", "-h", "-V",
        "--alias", "--all-fqdns", "--domain", "--fqdn", "--long",
        "--ip-address", "--all-ip-addresses", "--short",
        "--version", "--help",
    ]

    private static let dateValueOptions: Set<String> = [
        "-d", "--date", "-f", "--file", "-r", "--reference",
    ]

    private static let dateReadOnlyLongFlags: Set<String> = [
        "--utc", "--universal", "--debug", "--help", "--version", "--rfc-email",
        "--iso-8601",
    ]

    private static let ipReadOnlyCommands: Set<String> = [
        "show", "list", "lst", "help", "get", "monitor", "save",
    ]

    /// 是否命中禁止高危模式。
    /// `mkfs` 按词边界匹配（`mkfs.ext4` 命中，`notmkfs` / `mkfilesystem` 不命中）。
    /// `rm` 解析标志：只有递归删除 `/`、`/*`、`~`、`~/`、`$HOME` 或顶层系统目录时才禁止。
    static func isForbidden(_ cmd: String) -> Bool {
        let trimmed = cmd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if containsMkfsWord(trimmed) || containsForbiddenRecursiveRm(trimmed) {
            return true
        }
        for pattern in forbiddenPatterns {
            if let regex = try? Regex(pattern), trimmed.contains(regex) { return true }
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
    /// 不做引号处理；审批前缀匹配继续用这个稳定切分。
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

    /// 整条命令是否可自动放行（每一段都是只读形式）。
    /// 包装器（`env` 带子命令、`sudo`、`sh -c` 等）不是只读形式。
    static func isAutoSafe(_ cmd: String) -> Bool {
        let trimmed = cmd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        // 命令替换 / 进程替换的实际命令不在本段 argv 里，无法证明只读。
        if trimmed.contains("$(") || trimmed.contains("`") || trimmed.contains("<(") || trimmed.contains(">(") {
            return false
        }
        let segments = shellSegments(trimmed)
        guard !segments.isEmpty else { return false }
        return segments.allSatisfy(segmentIsAutoSafe)
    }

    /// 检查命令是否可自动放行。保留原名，语义改为整段只读判定，而不只是首词。
    static func matchesSafeCommand(_ cmd: String) -> Bool {
        isAutoSafe(cmd)
    }

    /// `execute_ssh_command` 的安全级别。`isDestructive == true` 只能把只读命令升到需要确认。
    static func classifyCommand(_ command: String, isDestructive: Bool) -> SafetyLevel {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        if isForbidden(trimmed) { return .forbidden }
        if isAutoSafe(trimmed), !hasInjectionOrRedirection(trimmed), !isDestructive {
            return .safe
        }
        return .needsConfirmation
    }

    // MARK: - 自动放行

    private static func segmentIsAutoSafe(_ tokens: [String]) -> Bool {
        guard let name = tokens.first, !name.isEmpty, !name.contains("/"), !name.contains("=") else {
            return false
        }
        if name == "env" {
            return envPrintsOnly(tokens)
        }
        if blockingWrappers.contains(name) {
            return false
        }
        let args = Array(tokens.dropFirst())
        switch name {
        case "hostname":
            return hostnameIsReadOnly(args)
        case "date":
            return dateIsReadOnly(args)
        case "find":
            return findIsReadOnly(args)
        case "ip":
            return ipIsReadOnly(args)
        case "git":
            return gitIsReadOnly(args)
        case "docker":
            return dockerIsReadOnly(args)
        case "systemctl":
            return systemctlIsReadOnly(args)
        default:
            return simpleReadOnlyCommands.contains(name)
        }
    }

    /// `env` 没带要执行的命令时只打印环境，保持自动放行；一旦包装了子命令就不再放行。
    private static func envPrintsOnly(_ tokens: [String]) -> Bool {
        var index = 1
        while index < tokens.count {
            let token = tokens[index]
            if token == "--" || token == "-" {
                index += 1
                break
            }
            if token.hasPrefix("-") {
                if token == "-i" || token == "--ignore-environment"
                    || token == "-0" || token == "--null"
                    || token == "-v" || token == "--debug"
                    || token == "--help" || token == "--version" {
                    index += 1
                    continue
                }
                if token == "-u" || token == "--unset" || token == "-C" || token == "--chdir" {
                    guard index + 1 < tokens.count else { return false }
                    index += 2
                    continue
                }
                if token.hasPrefix("--unset=") || token.hasPrefix("--chdir=")
                    || token.hasPrefix("--default-signal")
                    || token.hasPrefix("--ignore-signal")
                    || token.hasPrefix("--block-signal")
                    || token.hasPrefix("--list-signal") {
                    index += 1
                    continue
                }
                // `-S` 或未知选项可能把命令藏在参数里。
                return false
            }
            break
        }
        while index < tokens.count, isEnvironmentAssignment(tokens[index]) {
            index += 1
        }
        return index == tokens.count
    }

    private static func isEnvironmentAssignment(_ token: String) -> Bool {
        guard let separator = token.firstIndex(of: "="), separator != token.startIndex else { return false }
        let name = token[..<separator]
        guard let first = name.first, first.isLetter || first == "_" else { return false }
        return name.dropFirst().allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    private static func hostnameIsReadOnly(_ args: [String]) -> Bool {
        args.allSatisfy { hostnameReadOnlyFlags.contains($0) }
    }

    private static func dateIsReadOnly(_ args: [String]) -> Bool {
        var index = 0
        while index < args.count {
            let arg = args[index]
            if arg == "--" {
                return args[(index + 1)...].allSatisfy { $0.hasPrefix("+") }
            }
            if arg == "-s" || arg == "--set" || arg.hasPrefix("--set=") {
                return false
            }
            if arg.hasPrefix("--date=") || arg.hasPrefix("--file=") || arg.hasPrefix("--reference=")
                || arg.hasPrefix("--iso-8601") {
                index += 1
                continue
            }
            if arg == "--rfc-3339" {
                guard index + 1 < args.count else { return false }
                index += 2
                continue
            }
            if arg.hasPrefix("--rfc-3339=") {
                index += 1
                continue
            }
            if arg == "-I" || (arg.hasPrefix("-I") && arg.dropFirst(2).allSatisfy(\.isLetter)) {
                index += 1
                continue
            }
            if dateValueOptions.contains(arg) {
                guard index + 1 < args.count else { return false }
                index += 2
                continue
            }
            if arg.hasPrefix("--") {
                if dateReadOnlyLongFlags.contains(arg) {
                    index += 1
                    continue
                }
                return false
            }
            if arg.hasPrefix("-"), arg != "-" {
                let letters = arg.dropFirst()
                if letters.contains(where: { $0 == "s" }) { return false }
                if letters.contains(where: { $0 == "d" || $0 == "f" || $0 == "r" }) {
                    guard index + 1 < args.count else { return false }
                    index += 2
                    continue
                }
                index += 1
                continue
            }
            if arg.hasPrefix("+") {
                index += 1
                continue
            }
            return false
        }
        return true
    }

    private static func findIsReadOnly(_ args: [String]) -> Bool {
        !args.contains { findMutatingOptions.contains($0) }
    }

    private static func ipIsReadOnly(_ args: [String]) -> Bool {
        var index = 0
        while index < args.count {
            let arg = args[index]
            if arg == "-b" || arg == "-batch" || arg == "--batch" || arg == "-force" {
                return false
            }
            if arg == "-n" || arg == "-netns" || arg == "--netns"
                || arg == "-f" || arg == "-family" || arg == "--family"
                || arg == "-l" || arg == "-loops" || arg == "-rcvbuf" {
                guard index + 1 < args.count else { return false }
                index += 2
                continue
            }
            if arg.hasPrefix("-") {
                index += 1
                continue
            }
            break
        }
        guard index < args.count else { return true }
        index += 1
        while index < args.count, args[index].hasPrefix("-") {
            index += 1
        }
        guard index < args.count else { return true }
        return ipReadOnlyCommands.contains(args[index])
    }

    private static func gitIsReadOnly(_ args: [String]) -> Bool {
        guard let subcommand = args.first else { return false }
        let rest = args.dropFirst()
        switch subcommand {
        case "status", "log":
            return true
        case "diff":
            return !rest.contains { $0 == "--output" || $0.hasPrefix("--output=") }
        case "branch":
            return !rest.contains(where: isGitBranchDeleteFlag)
        default:
            return false
        }
    }

    private static func isGitBranchDeleteFlag(_ arg: String) -> Bool {
        if arg == "-d" || arg == "-D" || arg == "--delete" { return true }
        guard arg.hasPrefix("-"), !arg.hasPrefix("--") else { return false }
        return arg.dropFirst().contains { $0 == "d" || $0 == "D" }
    }

    private static func dockerIsReadOnly(_ args: [String]) -> Bool {
        guard let subcommand = args.first else { return false }
        return subcommand == "ps" || subcommand == "images" || subcommand == "logs"
    }

    private static func systemctlIsReadOnly(_ args: [String]) -> Bool {
        args.first == "status"
    }

    // MARK: - rm / mkfs

    private static func containsMkfsWord(_ text: String) -> Bool {
        let chars = Array(text)
        var index = 0
        while index < chars.count {
            if isBareWord(chars, at: index, word: "mkfs") { return true }
            index += 1
        }
        return false
    }

    private static func containsForbiddenRecursiveRm(_ text: String) -> Bool {
        let chars = Array(text)
        var index = 0
        while index < chars.count {
            if isBareWord(chars, at: index, word: "rm") {
                let tail = String(chars[index...])
                if rmCommandIsProtected(tail) { return true }
                index += 2
                continue
            }
            index += 1
        }
        return false
    }

    private static func isBareWord(_ chars: [Character], at index: Int, word: String) -> Bool {
        let wordChars = Array(word)
        guard index + wordChars.count <= chars.count else { return false }
        for (offset, expected) in wordChars.enumerated() where chars[index + offset] != expected {
            return false
        }
        if index > 0, isWordCharacter(chars[index - 1]) { return false }
        let after = index + wordChars.count
        if after < chars.count, isWordCharacter(chars[after]) { return false }
        return true
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }

    private static func rmCommandIsProtected(_ textStartingAtRm: String) -> Bool {
        guard let segment = shellSegments(textStartingAtRm).first, let command = segment.first else {
            return false
        }
        guard commandBasename(command) == "rm" else { return false }
        return rmArgsAreProtected(Array(segment.dropFirst()))
    }

    private static func commandBasename(_ token: String) -> String {
        guard let slash = token.lastIndex(of: "/") else { return token }
        let name = token[token.index(after: slash)...]
        return name.isEmpty ? token : String(name)
    }

    private static func rmArgsAreProtected(_ args: [String]) -> Bool {
        var recursive = false
        var targets: [String] = []
        var index = 0
        while index < args.count {
            let arg = args[index]
            if arg == "--" {
                targets.append(contentsOf: args[(index + 1)...])
                break
            }
            if arg == "--recursive" || arg.hasPrefix("--recursive=") {
                recursive = true
                index += 1
                continue
            }
            if arg.hasPrefix("--") {
                index += 1
                continue
            }
            if arg.hasPrefix("-"), arg != "-" {
                let letters = arg.dropFirst()
                if letters.contains(where: { $0 == "r" || $0 == "R" }) {
                    recursive = true
                }
                index += 1
                continue
            }
            targets.append(arg)
            index += 1
        }
        guard recursive else { return false }
        return targets.contains(where: isProtectedRmTarget)
    }

    private static func isProtectedRmTarget(_ raw: String) -> Bool {
        let text = normalizeRmTarget(raw)
        guard !text.isEmpty else { return false }
        if isProtectedHomeTarget(text) { return true }
        return isProtectedAbsoluteRmTarget(text)
    }

    /// 去掉包在目标两侧的引号和语句结束符，避免 `rm -rf /")` 这类嵌入调用漏判。
    /// 不剥 `$`、`{}`，以便 `${HOME}` 仍能整段识别。
    private static func normalizeRmTarget(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let junk: Set<Character> = ["\"", "'", "`", ")", "]", ",", ";"]
        while let first = text.first, junk.contains(first) {
            text.removeFirst()
        }
        while let last = text.last, junk.contains(last) {
            text.removeLast()
        }
        return text
    }

    private static func isProtectedHomeTarget(_ text: String) -> Bool {
        for base in ["${HOME}", "$HOME", "~"] where matchesProtectedHome(text, base: base) {
            return true
        }
        return false
    }

    private static func matchesProtectedHome(_ text: String, base: String) -> Bool {
        guard text.hasPrefix(base) else { return false }
        var rest = text.dropFirst(base.count)
        if rest.hasPrefix("/") {
            while rest.hasPrefix("/") {
                rest = rest.dropFirst()
            }
            return rest.isEmpty || rest == "*"
        }
        return rest.isEmpty || rest == "*"
    }

    private static func isProtectedAbsoluteRmTarget(_ raw: String) -> Bool {
        var path = raw
        guard path.hasPrefix("/") else { return false }
        if path.hasSuffix("/*") {
            path.removeLast(2)
            if path.isEmpty { path = "/" }
        }
        while path.contains("//") {
            path = path.replacingOccurrences(of: "//", with: "/")
        }
        if path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        let rawParts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        var parts: [String] = []
        for part in rawParts {
            if part == "." { continue }
            if part == ".." {
                if !parts.isEmpty { parts.removeLast() }
                continue
            }
            parts.append(part)
        }
        if parts.isEmpty { return true }
        return parts.count == 1 && protectedTopLevelDirectories.contains(parts[0])
    }

    // MARK: - 引号感知分段

    /// 按 `;`、`|`、`&`、换行切开命令，但保留引号内的内容。`2>&1` 里的 `&` 不切开。
    private static func shellSegments(_ command: String) -> [[String]] {
        var segments: [[String]] = []
        var current: [String] = []
        var token = ""
        var hasToken = false
        var quote: Character = "\0"
        var escaping = false

        func flushToken() {
            if hasToken {
                current.append(token)
                token = ""
                hasToken = false
            }
        }

        func flushSegment() {
            flushToken()
            if !current.isEmpty {
                segments.append(current)
                current = []
            }
        }

        let chars = Array(command)
        var index = 0
        while index < chars.count {
            let character = chars[index]
            if quote == "'" {
                if character == "'" {
                    quote = "\0"
                } else {
                    token.append(character)
                    hasToken = true
                }
                index += 1
                continue
            }
            if quote == "\"" {
                if escaping {
                    if character != "\n" && character != "\r" {
                        token.append(character)
                        hasToken = true
                    }
                    escaping = false
                    index += 1
                    continue
                }
                if character == "\\" {
                    escaping = true
                    index += 1
                    continue
                }
                if character == "\"" {
                    quote = "\0"
                    hasToken = true
                    index += 1
                    continue
                }
                token.append(character)
                hasToken = true
                index += 1
                continue
            }
            if escaping {
                if character != "\n" && character != "\r" {
                    token.append(character)
                    hasToken = true
                }
                escaping = false
                index += 1
                continue
            }
            if character == "\\" {
                escaping = true
                index += 1
                continue
            }
            if character == "'" || character == "\"" {
                quote = character
                hasToken = true
                index += 1
                continue
            }
            if character == " " || character == "\t" {
                flushToken()
                index += 1
                continue
            }
            if character == "\n" || character == "\r" || character == ";" {
                flushSegment()
                index += 1
                continue
            }
            if character == "|" {
                flushSegment()
                if index + 1 < chars.count, chars[index + 1] == "|" {
                    index += 2
                } else {
                    index += 1
                }
                continue
            }
            if character == "&" {
                if token.hasSuffix(">") {
                    token.append(character)
                    hasToken = true
                    index += 1
                    continue
                }
                flushSegment()
                if index + 1 < chars.count, chars[index + 1] == "&" {
                    index += 2
                } else {
                    index += 1
                }
                continue
            }
            token.append(character)
            hasToken = true
            index += 1
        }
        flushSegment()
        return segments
    }
}
