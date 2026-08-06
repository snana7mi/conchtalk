/// 文件说明：GlobTool，在远端服务器上按文件名模式查找文件。
import Foundation

/// GlobTool：
/// 使用 find 命令按 glob 模式查找远端文件，支持类型过滤和深度限制。
/// 比让 AI 手写 find 命令更直观，且自动处理跨平台兼容。
nonisolated struct GlobTool: ToolProtocol, @unchecked Sendable {
    let name = "find_files"
    let description = """
        Prefer this over execute_ssh_command with find. \
        Find files on the remote server by name or path pattern using glob syntax. \
        Returns matching file paths sorted by modification time (newest first). \
        Handles cross-platform compatibility automatically. \
        Supports standard glob patterns (e.g. "*.conf", "nginx*", "*.log").
        """

    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "pattern": [
                "type": "string",
                "description": "Glob pattern to match file names (e.g. \"*.conf\", \"nginx*\", \"docker-compose*.yml\")",
            ] as [String: String],
            "path": [
                "type": "string",
                "description": "Base directory to search from. Defaults to current directory if omitted.",
            ] as [String: String],
            "max_depth": [
                "type": "integer",
                "description": "Maximum directory recursion depth. Defaults to 5. Range: 1-10.",
            ] as [String: String],
            "type": [
                "type": "string",
                "enum": ["file", "directory", "any"],
                "description": "Filter by entry type: \"file\" (default), \"directory\", or \"any\".",
            ] as [String: Any],
            "explanation": [
                "type": "string",
                "description": "A brief explanation of why you are searching for these files",
            ] as [String: String],
        ] as [String: Any],
        "required": ["pattern", "explanation"],
    ]

    /// 文件查找为只读操作，可直接执行。
    func validateSafety(arguments: [String: Any]) -> SafetyLevel {
        .safe
    }

    /// 使用 find 命令查找匹配文件，结果按修改时间排序。
    func execute(arguments: [String: Any], sshClient: SSHClientProtocol) async throws -> ToolExecutionResult {
        guard let pattern = arguments["pattern"] as? String else {
            throw ToolError.missingParameter("pattern")
        }

        let path = (arguments["path"] as? String) ?? "."
        let maxDepth = max(1, min((arguments["max_depth"] as? Int) ?? 5, 10))
        let type = (arguments["type"] as? String) ?? "file"

        let escapedPath = shellEscape(path)
        let escapedPattern = shellEscape(pattern)

        // 构建 find 命令
        var findParts = ["find", escapedPath]
        findParts.append("-maxdepth \(maxDepth)")

        // 排除 .git 目录
        findParts.append("-not -path '*/.git/*'")

        // 类型过滤
        switch type {
        case "file":
            findParts.append("-type f")
        case "directory":
            findParts.append("-type d")
        default:
            break // "any" → 不加类型过滤
        }

        // 名称匹配：包含 / 时用 -path，否则用 -name
        if pattern.contains("/") {
            findParts.append("-path \(escapedPattern)")
        } else {
            findParts.append("-name \(escapedPattern)")
        }

        findParts.append("2>/dev/null")

        let findBase = findParts.joined(separator: " ")

        // 按修改时间排序（GNU find 用 -printf，不可用时回退）
        // 使用 ls -t 作为通用排序方案，兼容 GNU 和 BSD
        let command = "\(findBase) -exec ls -1dt {} + 2>/dev/null | head -100"

        let output = try await sshClient.execute(command: command)
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.isEmpty {
            return ToolExecutionResult(output: "No files found matching pattern: \(pattern)")
        }

        return ToolExecutionResult(output: trimmed)
    }
}
