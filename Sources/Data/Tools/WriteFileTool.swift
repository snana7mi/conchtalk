/// 文件说明：WriteFileTool，提供远端文件写入能力，支持文本/二进制、追加、备份。
import Foundation

/// WriteFileTool：
/// 统一的文件写入工具，自动选择 SSH 或 SFTP 通道：
/// - 文本写入 → SSH heredoc（支持追加、自动创建父目录）
/// - 二进制写入 → SFTP（Base64 解码后写入）
/// - 可选在写入前备份原文件为 .bak
nonisolated struct WriteFileTool: ToolProtocol, @unchecked Sendable {
    let name = "write_file"
    let description = "Prefer this over execute_ssh_command with sed/tee/echo. Write content to a file on the remote server. Supports text (overwrite/append) and binary (base64) modes, with optional backup."

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
            "append": [
                "type": "boolean",
                "description": "If true, append to the file instead of overwriting. Only for text mode. Defaults to false.",
            ] as [String: String],
            "encoding": [
                "type": "string",
                "description": "Encoding mode: \"text\" for plain text (default), \"base64\" for binary content.",
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

    func validateSafety(arguments: [String: Any]) -> SafetyLevel {
        .needsConfirmation
    }

    func execute(arguments: [String: Any], sshClient: SSHClientProtocol) async throws -> ToolExecutionResult {
        guard let path = arguments["path"] as? String else {
            throw ToolError.missingParameter("path")
        }
        guard let content = arguments["content"] as? String else {
            throw ToolError.missingParameter("content")
        }

        let encoding = arguments["encoding"] as? String ?? "text"
        let append = arguments["append"] as? Bool ?? false
        let createBackup = arguments["create_backup"] as? Bool ?? false

        // Base64 + append 不兼容
        if encoding == "base64" && append {
            throw ToolError.invalidArguments("Append mode is not supported for base64 encoding")
        }

        // 写入前备份
        if createBackup {
            if let existingData = try? await sshClient.sftpReadFile(path: path) {
                try? await sshClient.sftpWriteFile(path: path + ".bak", data: existingData)
            }
        }

        if encoding == "base64" {
            // 二进制模式：SFTP 写入
            guard let decoded = Data(base64Encoded: content) else {
                throw ToolError.invalidArguments("Invalid base64 encoding in content")
            }
            try await sshClient.sftpWriteFile(path: path, data: decoded)
            let size = try await sshClient.sftpFileSize(path: path)
            return ToolExecutionResult(output: "Written to \(path) successfully (\(size) bytes)")
        } else {
            // 文本模式：SSH heredoc
            let op = append ? ">>" : ">"
            let delimiter = "CONCHTALK_EOF_\(UUID().uuidString.prefix(8))"
            let command = "cat <<'\(delimiter)' \(op) \(shellEscape(path))\n\(content)\n\(delimiter)"

            // 自动创建父目录
            let dir = (path as NSString).deletingLastPathComponent
            if !dir.isEmpty && dir != "/" {
                _ = try await sshClient.execute(command: "mkdir -p \(shellEscape(dir))")
            }

            let output = try await sshClient.execute(command: command)
            let verify = try await sshClient.execute(command: "wc -c < \(shellEscape(path))")
            let byteCount = verify.trimmingCharacters(in: .whitespacesAndNewlines)
            let verb = append ? "Appended to" : "Written to"
            let result = output.isEmpty ? "\(verb) \(path) successfully (\(byteCount) bytes)" : output
            return ToolExecutionResult(output: result)
        }
    }
}
