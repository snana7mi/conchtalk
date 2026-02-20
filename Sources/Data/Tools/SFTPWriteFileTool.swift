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

    /// 通过原生 SFTP 写入远端文件。
    /// - 文本模式：将文本内容以 UTF-8 编码写入。
    /// - Base64 模式：将 Base64 编码内容解码后写入，适用于二进制文件。
    /// - 可选在写入前通过 SFTP 备份原文件为 `.bak`。
    /// - Parameters:
    ///   - arguments: 需包含 `path`、`content`，可选 `encoding`（默认 `"text"`）、`create_backup`（默认 `false`）。
    ///   - sshClient: SSH 执行客户端。
    /// - Returns: 写入成功提示与文件大小验证信息。
    /// - Throws: 参数缺失、编码失败或 SFTP 写入失败时抛出。
    func execute(arguments: [String: Any], sshClient: SSHClientProtocol) async throws -> ToolExecutionResult {
        guard let path = arguments["path"] as? String else {
            throw ToolError.missingParameter("path")
        }
        guard let content = arguments["content"] as? String else {
            throw ToolError.missingParameter("content")
        }

        let encoding = arguments["encoding"] as? String ?? "text"
        let createBackup = arguments["create_backup"] as? Bool ?? false

        // 如需备份，通过 SFTP 读取原文件并写为 .bak（忽略文件不存在的情况）。
        if createBackup {
            if let existingData = try? await sshClient.sftpReadFile(path: path) {
                try? await sshClient.sftpWriteFile(path: path + ".bak", data: existingData)
            }
        }

        let writeData: Data
        if encoding == "base64" {
            guard let decoded = Data(base64Encoded: content) else {
                throw ToolError.invalidArguments("Invalid base64 encoding in content")
            }
            writeData = decoded
        } else {
            guard let textData = content.data(using: .utf8) else {
                throw ToolError.invalidArguments("Unable to encode content as UTF-8")
            }
            writeData = textData
        }

        try await sshClient.sftpWriteFile(path: path, data: writeData)

        // 验证写入后的文件大小
        let size = try await sshClient.sftpFileSize(path: path)
        return ToolExecutionResult(output: "Written to \(path) successfully (\(size) bytes)")
    }
}
