/// 文件说明：ListDirectoryTool，提供远端目录列表与基础文件信息查询。
import Foundation

/// ListDirectoryTool：
/// 使用 `ls` 列出目录内容，支持显示隐藏文件与长格式详情，
/// 便于模型先感知目录结构再决定后续操作。
struct ListDirectoryTool: ToolProtocol {
    let name = "list_directory"
    let description = "List files and directories at the specified path on the remote server."

    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "path": [
                "type": "string",
                "description": "Absolute path to the directory to list. Defaults to current directory if omitted.",
            ] as [String: String],
            "show_hidden": [
                "type": "boolean",
                "description": "Whether to show hidden files (dotfiles). Defaults to false.",
            ] as [String: String],
            "long_format": [
                "type": "boolean",
                "description": "Whether to use long format (permissions, size, date). Defaults to true.",
            ] as [String: String],
            "explanation": [
                "type": "string",
                "description": "A brief explanation of why you are listing this directory",
            ] as [String: String],
        ] as [String: [String: String]],
        "required": ["explanation"],
    ]

    /// 目录列表查询为只读操作，可直接执行。
    func validateSafety(arguments: [String: Any]) -> SafetyLevel {
        .safe
    }

    /// 执行目录列表命令并返回结果文本。
    /// - Parameters:
    ///   - arguments: 可选 `path`、`show_hidden`、`long_format`。
    ///   - sshClient: SSH 执行客户端。
    /// - Returns: `ls` 命令输出内容。
    /// - Throws: 远端命令执行失败时抛出。
    func execute(arguments: [String: Any], sshClient: SSHClientProtocol) async throws -> ToolExecutionResult {
        let path = (arguments["path"] as? String) ?? "."
        let showHidden = arguments["show_hidden"] as? Bool ?? false
        let longFormat = arguments["long_format"] as? Bool ?? true

        var flags = ""
        if longFormat { flags += "l" }
        if showHidden { flags += "a" }
        flags += "h" // human-readable sizes

        let command = "ls -\(flags) \(shellEscape(path))"
        let output = try await sshClient.execute(command: command)
        return ToolExecutionResult(output: output)
    }
}
