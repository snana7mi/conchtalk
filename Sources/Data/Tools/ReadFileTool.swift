/// 文件说明：ReadFileTool，提供远端文件内容读取能力，支持行范围截取与二进制 Base64 编码。
import Foundation

/// ReadFileTool：
/// 统一的文件读取工具，自动选择 SSH 或 SFTP 通道：
/// - 文本 + 行范围 → SSH（sed/head/tail）
/// - 二进制 / Base64 → SFTP
/// - 全文读取 → 优先 SFTP，失败回退 SSH
nonisolated struct ReadFileTool: ToolProtocol, @unchecked Sendable {
    let name = "read_file"
    let description = "Prefer this over execute_ssh_command with cat/head/tail for better output handling. Read the contents of a file on the remote server. Supports line ranges for text files and base64 encoding for binary files."

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
            "encoding": [
                "type": "string",
                "description": "Encoding mode: \"text\" for plain text (default), \"base64\" for binary-safe base64 output.",
                "enum": ["text", "base64"],
            ] as [String: Any],
            "explanation": [
                "type": "string",
                "description": "A brief explanation of why you are reading this file",
            ] as [String: String],
        ] as [String: Any],
        "required": ["path", "explanation"],
    ]

    func validateSafety(arguments: [String: Any]) -> SafetyLevel {
        .safe
    }

    func execute(arguments: [String: Any], sshClient: SSHClientProtocol) async throws -> ToolExecutionResult {
        guard let path = arguments["path"] as? String else {
            throw ToolError.missingParameter("path")
        }

        let encoding = arguments["encoding"] as? String ?? "text"
        let startLine = arguments["start_line"] as? Int
        let endLine = arguments["end_line"] as? Int

        // Base64 模式：必须走 SFTP
        if encoding == "base64" {
            let data = try await sshClient.sftpReadFile(path: path)
            return ToolExecutionResult(output: "Base64 encoded content of \(path) (\(data.count) bytes):\n\(data.base64EncodedString())")
        }

        // 文本模式 + 行范围：走 SSH
        if startLine != nil || endLine != nil {
            var command: String
            if let s = startLine, let e = endLine {
                command = "sed -n '\(s),\(e)p' \(shellEscape(path))"
            } else if let s = startLine {
                command = "tail -n +\(s) \(shellEscape(path))"
            } else {
                command = "head -n \(endLine!) \(shellEscape(path))"
            }
            let output = try await sshClient.execute(command: command)
            return ToolExecutionResult(output: output)
        }

        // 文本模式 + 全文：优先 SFTP，失败回退 SSH
        do {
            let data = try await sshClient.sftpReadFile(path: path)
            if let text = String(data: data, encoding: .utf8) {
                return ToolExecutionResult(output: "File: \(path) (\(data.count) bytes)\n---\n\(text)")
            } else {
                // 二进制文件，自动转 Base64
                return ToolExecutionResult(output: "Binary file \(path) (\(data.count) bytes), base64 encoded:\n\(data.base64EncodedString())")
            }
        } catch {
            let output = try await sshClient.execute(command: "cat \(shellEscape(path))")
            return ToolExecutionResult(output: output)
        }
    }
}
