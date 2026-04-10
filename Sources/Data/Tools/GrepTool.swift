/// 文件说明：GrepTool，在远端服务器上用正则表达式搜索文件内容。
import Foundation

/// GrepTool：
/// 优先使用 ripgrep（rg），不可用时回退到 grep -rn。
/// 返回匹配的文件路径、行号和上下文行，方便 AI 快速定位相关代码/配置。
nonisolated struct GrepTool: ToolProtocol, @unchecked Sendable {
    let name = "grep_files"
    let description = """
        Prefer this over execute_ssh_command with grep. \
        Search file contents on the remote server using regular expressions. \
        Returns matching file paths, line numbers, and context lines. \
        Handles tool availability detection (ripgrep vs grep) and output formatting automatically. \
        Supports regex syntax (e.g. "log.*error", "listen\\s+\\d+").
        """

    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "pattern": [
                "type": "string",
                "description": "Regular expression pattern to search for (e.g. \"error.*timeout\", \"port\\s*=\\s*\\d+\")",
            ] as [String: String],
            "path": [
                "type": "string",
                "description": "Directory to search in. Defaults to current directory if omitted.",
            ] as [String: String],
            "include": [
                "type": "string",
                "description": "File glob filter to narrow search scope (e.g. \"*.conf\", \"*.log\", \"*.py\"). Omit to search all text files.",
            ] as [String: String],
            "max_results": [
                "type": "integer",
                "description": "Maximum number of matching lines to return. Defaults to 50. Range: 1-200.",
            ] as [String: String],
            "explanation": [
                "type": "string",
                "description": "A brief explanation of why you are searching for this pattern",
            ] as [String: String],
        ] as [String: [String: String]],
        "required": ["pattern", "explanation"],
    ]

    /// 搜索文件内容为只读操作，可直接执行。
    func validateSafety(arguments: [String: Any]) -> SafetyLevel {
        .safe
    }

    /// 优先使用 rg，不可用时回退到 grep -rn。
    func execute(arguments: [String: Any], sshClient: SSHClientProtocol) async throws -> ToolExecutionResult {
        guard let pattern = arguments["pattern"] as? String else {
            throw ToolError.missingParameter("pattern")
        }

        let path = (arguments["path"] as? String) ?? "."
        let include = arguments["include"] as? String
        let maxResults = min(max((arguments["max_results"] as? Int) ?? 50, 1), 200)

        let escapedPattern = shellEscape(pattern)
        let escapedPath = shellEscape(path)

        // rg 命令：自动跳过二进制文件和 .git/
        var rgCmd = "rg --no-heading -n --max-count \(maxResults)"
        if let include {
            rgCmd += " --glob \(shellEscape(include))"
        }
        rgCmd += " \(escapedPattern) \(escapedPath) 2>/dev/null"

        // grep 回退：需手动排除 .git/ 和二进制文件
        var grepCmd = "grep -rn --exclude-dir=.git --binary-files=without-match"
        if let include {
            grepCmd += " --include=\(shellEscape(include))"
        }
        grepCmd += " -m \(maxResults) \(escapedPattern) \(escapedPath) 2>/dev/null"

        // 用 || true 兜底：无匹配时 grep/rg 返回非零退出码，不应当作错误
        let command = "if command -v rg >/dev/null 2>&1; then \(rgCmd) || true; else \(grepCmd) || true; fi"

        let output = try await sshClient.execute(command: command)
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.isEmpty {
            return ToolExecutionResult(output: "No matches found for pattern: \(pattern)")
        }

        return ToolExecutionResult(output: trimmed)
    }
}
