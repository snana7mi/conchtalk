/// 文件说明：SFTPReadFileTool，提供远端文件 SFTP 兼容读取能力，支持二进制文件的 Base64 编码传输。
import Foundation

/// SFTPReadFileTool：
/// 以 SFTP 兼容方式读取远端文件内容，支持纯文本与 Base64 两种编码模式，
/// 在普通 `cat` 读取失败或需要处理二进制文件时作为备选方案。
struct SFTPReadFileTool: ToolProtocol {
    let name = "sftp_read_file"
    let description = "Read a file from the remote server using SFTP-compatible method. Supports binary files by returning base64-encoded content. Use this for binary files or when cat-based reading fails."

    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "path": [
                "type": "string",
                "description": "Absolute path to the file to read",
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

    /// 读取文件为只读操作，可直接执行。
    func validateSafety(arguments: [String: Any]) -> SafetyLevel {
        .safe
    }

    /// 根据编码模式读取远端文件内容。
    /// - 文本模式：先获取文件元信息（类型与大小），再读取全文。
    /// - Base64 模式：将文件二进制内容编码为 Base64 返回，适用于二进制文件。
    /// - Parameters:
    ///   - arguments: 需包含 `path`，可选 `encoding`（默认 `"text"`）。
    ///   - sshClient: SSH 执行客户端。
    /// - Returns: 文件内容（纯文本或 Base64 编码）。
    /// - Throws: 参数缺失或远端读取失败时抛出。
    func execute(arguments: [String: Any], sshClient: SSHClientProtocol) async throws -> ToolExecutionResult {
        guard let path = arguments["path"] as? String else {
            throw ToolError.missingParameter("path")
        }

        let encoding = arguments["encoding"] as? String ?? "text"
        let escapedPath = shellEscape(path)

        if encoding == "base64" {
            let output = try await sshClient.execute(command: "base64 < \(escapedPath)")
            return ToolExecutionResult(output: "Base64 encoded content of \(path):\n\(output)")
        } else {
            let info = try await sshClient.execute(command: "file \(escapedPath) && wc -c < \(escapedPath)")
            let content = try await sshClient.execute(command: "cat \(escapedPath)")
            return ToolExecutionResult(output: "File info: \(info)\n---\n\(content)")
        }
    }
}
