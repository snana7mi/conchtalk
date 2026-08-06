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

        // 写入前备份：用户显式开启时，备份失败必须可见，不能静默吞错。
        if createBackup {
            do {
                let existingData = try await sshClient.sftpReadFile(path: path)
                try await sshClient.sftpWriteFile(path: path + ".bak", data: existingData)
            } catch {
                // 读不到原文件通常意味着首次写入（文件不存在），此时无需备份；
                // 但若文件确实存在（读/写 .bak 失败），属于真实备份失败，必须上报。
                if (try? await sshClient.sftpFileSize(path: path)) != nil {
                    throw ToolError.executionFailed("create_backup requested but backup failed: \(error.localizedDescription)")
                }
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
            // 文本模式：走 SFTP 二进制安全写入，避免 heredoc 分隔符碰撞 / shell 注入 /
            // 结尾多余换行等问题（旧实现用 `cat <<'DELIM'`，content 含与分隔符相同的行会截断）。
            guard let contentData = content.data(using: .utf8) else {
                throw ToolError.invalidArguments("Content is not valid UTF-8 text")
            }

            // 自动创建父目录（SFTP 写入不会自动建目录）
            let dir = (path as NSString).deletingLastPathComponent
            if !dir.isEmpty && dir != "/" {
                _ = try await sshClient.execute(command: "mkdir -p \(shellEscape(dir))")
            }

            let dataToWrite: Data
            if append {
                let existing = (try? await sshClient.sftpReadFile(path: path)) ?? Data()
                dataToWrite = existing + contentData
            } else {
                dataToWrite = contentData
            }
            try await sshClient.sftpWriteFile(path: path, data: dataToWrite)
            let size = try await sshClient.sftpFileSize(path: path)
            let verb = append ? "Appended to" : "Written to"
            return ToolExecutionResult(output: "\(verb) \(path) successfully (\(size) bytes)")
        }
    }
}
