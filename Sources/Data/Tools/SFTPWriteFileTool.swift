/// 文件说明：SFTPWriteFileTool，提供远端文件 SFTP 兼容写入能力，支持二进制内容的 Base64 解码写入。
import Foundation

/// SFTPWriteFileTool：
/// 以 SFTP 兼容方式将内容写入远端文件，支持纯文本与 Base64 两种编码模式，
/// 在 heredoc 写入失败或需要传输二进制内容时作为备选方案。
/// 可选在写入前自动备份原文件。
struct SFTPWriteFileTool: ToolProtocol {
    let name = "sftp_write_file"
    let description = "Write a file to the remote server using SFTP-compatible method. Supports binary files via base64 encoding. Use this for binary files or when heredoc-based writing fails."

    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "path": [
                "type": "string",
                "description": "Absolute path to the file to write",
            ] as [String: String],
            "content": [
                "type": "string",
                "description": "The content to write. Plain text for text mode, or base64-encoded string for base64 mode.",
            ] as [String: String],
            "encoding": [
                "type": "string",
                "description": "Encoding mode: \"text\" for plain text (default), \"base64\" for binary content (content must be base64-encoded).",
                "enum": ["text", "base64"],
            ] as [String: Any],
            "create_backup": [
                "type": "boolean",
                "description": "If true, create a .bak backup of the original file before writing. Defaults to false.",
            ] as [String: String],
            "explanation": [
                "type": "string",
                "description": "A brief explanation of what you are writing and why",
            ] as [String: String],
        ] as [String: Any],
        "required": ["path", "content", "explanation"],
    ]

    /// 写文件属于状态变更操作，默认要求用户确认后执行。
    func validateSafety(arguments: [String: Any]) -> SafetyLevel {
        .needsConfirmation
    }

    /// 执行远端文件写入。
    /// - 文本模式：通过 heredoc 传输纯文本内容。
    /// - Base64 模式：将 Base64 编码内容解码后写入，适用于二进制文件。
    /// - 可选在写入前备份原文件为 `.bak`。
    /// - Parameters:
    ///   - arguments: 需包含 `path`、`content`，可选 `encoding`（默认 `"text"`）、`create_backup`（默认 `false`）。
    ///   - sshClient: SSH 执行客户端。
    /// - Returns: 写入成功提示与文件大小验证信息。
    /// - Throws: 参数缺失或远端执行失败时抛出。
    func execute(arguments: [String: Any], sshClient: SSHClientProtocol) async throws -> ToolExecutionResult {
        guard let path = arguments["path"] as? String else {
            throw ToolError.missingParameter("path")
        }
        guard let content = arguments["content"] as? String else {
            throw ToolError.missingParameter("content")
        }

        let encoding = arguments["encoding"] as? String ?? "text"
        let createBackup = arguments["create_backup"] as? Bool ?? false
        let escapedPath = shellEscape(path)

        // 如需备份，先复制原文件（忽略文件不存在的情况）。
        if createBackup {
            _ = try? await sshClient.execute(command: "cp \(escapedPath) \(shellEscape(path + ".bak")) 2>/dev/null")
        }

        if encoding == "base64" {
            // 将 Base64 内容解码后写入目标文件。
            let command = "echo \(shellEscape(content)) | base64 -d > \(escapedPath)"
            let output = try await sshClient.execute(command: command)
            let size = try await sshClient.execute(command: "wc -c < \(escapedPath)")
            let result = output.isEmpty
                ? "Written to \(path) successfully (base64 decoded, \(size.trimmingCharacters(in: .whitespacesAndNewlines)) bytes)"
                : output
            return ToolExecutionResult(output: result)
        } else {
            // 使用 heredoc 传输纯文本内容，避免正文中引号导致命令拼接错误。
            let command = "cat <<'CONCHTALK_EOF' > \(escapedPath)\n\(content)\nCONCHTALK_EOF"
            let output = try await sshClient.execute(command: command)
            let result = output.isEmpty ? "Written to \(path) successfully" : output
            return ToolExecutionResult(output: result)
        }
    }
}
