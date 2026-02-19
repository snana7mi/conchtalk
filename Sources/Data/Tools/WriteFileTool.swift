/// 文件说明：WriteFileTool，提供远端文件写入/追加能力。
import Foundation

/// WriteFileTool：
/// 将文本内容写入远端文件，支持覆盖与追加两种模式，
/// 通过 heredoc 传输正文以降低转义复杂度。
struct WriteFileTool: ToolProtocol {
    let name = "write_file"
    let description = "Write content to a file on the remote server. Can overwrite or append."

    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "path": [
                "type": "string",
                "description": "Absolute path to the file to write",
            ] as [String: String],
            "content": [
                "type": "string",
                "description": "The content to write to the file",
            ] as [String: String],
            "append": [
                "type": "boolean",
                "description": "If true, append to the file instead of overwriting. Defaults to false.",
            ] as [String: String],
            "explanation": [
                "type": "string",
                "description": "A brief explanation of what you are writing and why",
            ] as [String: String],
        ] as [String: [String: String]],
        "required": ["path", "content", "explanation"],
    ]

    /// 写文件属于状态变更操作，默认要求用户确认后执行。
    func validateSafety(arguments: [String: Any]) -> SafetyLevel {
        .needsConfirmation
    }

    /// 执行远端文件写入。
    /// - Parameters:
    ///   - arguments: 需包含 `path`、`content`，可选 `append`。
    ///   - sshClient: SSH 执行客户端。
    /// - Returns: 写入成功提示或远端命令输出。
    /// - Throws: 参数缺失或远端执行失败时抛出。
    func execute(arguments: [String: Any], sshClient: SSHClientProtocol) async throws -> ToolExecutionResult {
        guard let path = arguments["path"] as? String else {
            throw ToolError.missingParameter("path")
        }
        guard let content = arguments["content"] as? String else {
            throw ToolError.missingParameter("content")
        }

        let append = arguments["append"] as? Bool ?? false
        let op = append ? ">>" : ">"
        // 使用 heredoc 传输内容，避免正文中引号导致命令拼接错误。
        let command = "cat <<'CONCHTALK_EOF' \(op) \(shellEscape(path))\n\(content)\nCONCHTALK_EOF"

        let output = try await sshClient.execute(command: command)
        let verb = append ? "Appended to" : "Written to"
        let result = output.isEmpty ? "\(verb) \(path) successfully" : output
        return ToolExecutionResult(output: result)
    }
}
