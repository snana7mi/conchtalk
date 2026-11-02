/// 文件说明：ReadFileTool，提供远端文件内容读取能力，支持行范围截取与二进制 Base64 编码。
import Foundation

/// ReadFileTool：
/// 统一的文件读取工具，自动选择 SSH 或 SFTP 通道：
/// - 文本 + 行范围 → SSH（sed/head/tail）
/// - 二进制 / Base64 → SFTP
/// - 全文读取 → 优先 SFTP，失败回退 SSH
nonisolated struct ReadFileTool: ToolProtocol, @unchecked Sendable {
    let name = "read_file"
    let description = """
        Prefer this over execute_ssh_command with cat/head/tail for better output handling. \
        Read the contents of a file on the remote server. Supports line ranges for text files and base64 encoding for binary files. \
        Sensitive paths (private keys, .pem, .key, .env, /etc/shadow, and similar) require approval. \
        Text reads are capped at 1 MiB and binary files are refused unless encoding is base64 (still capped). \
        start_line and end_line are 1-based.
        """

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
        let path = arguments["path"] as? String ?? ""
        if ReadFilePolicy.isSensitivePath(path) { return .needsConfirmation }
        return .safe
    }

    func execute(arguments: [String: Any], sshClient: SSHClientProtocol) async throws -> ToolExecutionResult {
        guard let rawPath = arguments["path"] as? String else {
            throw ToolError.missingParameter("path")
        }
        let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)

        let encoding = arguments["encoding"] as? String ?? "text"
        let startLine = ToolArguments.int(arguments["start_line"])
        let endLine = ToolArguments.int(arguments["end_line"])

        // Base64 模式：先看大小，再整文件读取。超限直接拒绝。
        if encoding == "base64" {
            let size = try await sshClient.sftpFileSize(path: path)
            if size > UInt64(ReadFilePolicy.maxBytes) {
                throw ToolError.executionFailed(ReadFilePolicy.tooLargeMessage(byteCount: size))
            }
            let data = try await sshClient.sftpReadFile(path: path)
            if data.count > ReadFilePolicy.maxBytes {
                throw ToolError.executionFailed(ReadFilePolicy.tooLargeMessage(byteCount: UInt64(data.count)))
            }
            return ToolExecutionResult(output: "Base64 encoded content of \(path) (\(data.count) bytes):\n\(data.base64EncodedString())")
        }

        // 文本模式 + 行范围：先用前缀拒绝明显的二进制，行号从 1 开始。
        if startLine != nil || endLine != nil {
            try await refuseObviousBinary(path: path, sshClient: sshClient)
            let command = try ReadFilePolicy.lineCommand(path: path, start: startLine, end: endLine)
            let output = try await sshClient.execute(command: command, timeout: 60, reclaimOnTimeout: true)
            return ToolExecutionResult(output: output)
        }

        // 文本模式 + 全文：优先 SFTP，传输失败才回退到有上限的 SSH。
        do {
            return try await readTextViaSFTP(path: path, sshClient: sshClient)
        } catch let error as ToolError {
            throw error
        } catch {
            return try await readTextViaSSH(path: path, sshClient: sshClient)
        }
    }

    /// 文件开头像二进制时拒绝，避免把二进制流进 sed/tail。探测失败则交给后续读取。
    private func refuseObviousBinary(path: String, sshClient: SSHClientProtocol) async throws {
        guard let size = try? await sshClient.sftpFileSize(path: path), size > 0 else { return }
        let prefixCount = min(Int(size), ReadFilePolicy.probeBytes)
        guard let prefix = try? await sshClient.sftpReadPrefix(path: path, maxBytes: prefixCount) else { return }
        if ReadFilePolicy.looksBinary(prefix) {
            throw ToolError.executionFailed(ReadFilePolicy.binaryMessage)
        }
    }

    /// 先看大小和前缀，确认是可接受的文本后再读全文。
    private func readTextViaSFTP(path: String, sshClient: SSHClientProtocol) async throws -> ToolExecutionResult {
        let size = try await sshClient.sftpFileSize(path: path)
        if size > UInt64(ReadFilePolicy.maxBytes) {
            throw ToolError.executionFailed(ReadFilePolicy.tooLargeMessage(byteCount: size))
        }
        if size > 0 {
            let prefixCount = min(Int(size), ReadFilePolicy.probeBytes)
            let prefix = try await sshClient.sftpReadPrefix(path: path, maxBytes: prefixCount)
            if ReadFilePolicy.looksBinary(prefix) {
                throw ToolError.executionFailed(ReadFilePolicy.binaryMessage)
            }
        }
        let data = try await sshClient.sftpReadFile(path: path)
        return try textResult(path: path, data: data)
    }

    /// SFTP 不可用时只取有限前缀，不再 `cat` 整个文件。
    private func readTextViaSSH(path: String, sshClient: SSHClientProtocol) async throws -> ToolExecutionResult {
        let command = "head -c \(ReadFilePolicy.maxBytes + 1) \(shellEscape(path))"
        let output = try await sshClient.execute(command: command, timeout: 60, reclaimOnTimeout: true)
        if output.utf8.count > ReadFilePolicy.maxBytes {
            throw ToolError.executionFailed(ReadFilePolicy.tooLargeMessage(byteCount: UInt64(output.utf8.count)))
        }
        if output.contains("\0") {
            throw ToolError.executionFailed(ReadFilePolicy.binaryMessage)
        }
        return ToolExecutionResult(output: output)
    }

    /// 把已通过体积检查的数据格式化成文本结果。二进制或非法 UTF-8 在这里拒绝返回。
    private func textResult(path: String, data: Data) throws -> ToolExecutionResult {
        if data.count > ReadFilePolicy.maxBytes {
            throw ToolError.executionFailed(ReadFilePolicy.tooLargeMessage(byteCount: UInt64(data.count)))
        }
        if ReadFilePolicy.looksBinary(data) {
            throw ToolError.executionFailed(ReadFilePolicy.binaryMessage)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw ToolError.executionFailed(ReadFilePolicy.binaryMessage)
        }
        return ToolExecutionResult(output: "File: \(path) (\(data.count) bytes)\n---\n\(text)")
    }
}
