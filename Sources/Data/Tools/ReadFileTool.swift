/// 文件说明：ReadFileTool，提供远端文件内容读取与按行截取能力。
import Foundation

/// ReadFileTool：
/// 以只读方式获取远端文件内容，支持开始行/结束行参数，
/// 便于在大文件场景下做局部读取。
struct ReadFileTool: ToolProtocol {
    let name = "read_file"
    let description = "Read the contents of a file on the remote server. Supports reading entire files or specific line ranges."

    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "path": [
                "type": "string",
                "description": "Absolute path to the file to read",
            ] as [String: String],
            "start_line": [
                "type": "integer",
                "description": "Optional start line number (1-based). If omitted, reads from the beginning.",
            ] as [String: String],
            "end_line": [
                "type": "integer",
                "description": "Optional end line number (1-based, inclusive). If omitted, reads to the end.",
            ] as [String: String],
            "explanation": [
                "type": "string",
                "description": "A brief explanation of why you are reading this file",
            ] as [String: String],
        ] as [String: [String: String]],
        "required": ["path", "explanation"],
    ]

    /// 读取文件为只读操作，可直接执行。
    func validateSafety(arguments: [String: Any]) -> SafetyLevel {
        .safe
    }

    /// 根据行号范围选择合适命令读取文件内容。
    /// - Parameters:
    ///   - arguments: 需包含 `path`，可选 `start_line`、`end_line`。
    ///   - sshClient: SSH 执行客户端。
    /// - Returns: 文件全文或指定区间文本。
    /// - Throws: 参数缺失或远端读取失败时抛出。
    func execute(arguments: [String: Any], sshClient: SSHClientProtocol) async throws -> ToolExecutionResult {
        guard let path = arguments["path"] as? String else {
            throw ToolError.missingParameter("path")
        }

        var command: String
        if let startLine = arguments["start_line"] as? Int,
           let endLine = arguments["end_line"] as? Int {
            command = "sed -n '\(startLine),\(endLine)p' \(shellEscape(path))"
        } else if let startLine = arguments["start_line"] as? Int {
            command = "tail -n +\(startLine) \(shellEscape(path))"
        } else if let endLine = arguments["end_line"] as? Int {
            command = "head -n \(endLine) \(shellEscape(path))"
        } else {
            command = "cat \(shellEscape(path))"
        }

        let output = try await sshClient.execute(command: command)
        return ToolExecutionResult(output: output)
    }
}
