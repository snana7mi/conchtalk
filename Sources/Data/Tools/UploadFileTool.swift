/// 文件说明：UploadFileTool，将用户从本地设备选择的文件通过 SFTP 上传到远端服务器。
import Foundation

/// UploadFileTool：
/// 接收 AI 指定的文件名和远端路径，从内部注入的 `_attachments` 中取出对应文件数据，
/// 分块 SFTP 写入到远端，通过流式输出反馈上传进度。
nonisolated struct UploadFileTool: ToolProtocol, @unchecked Sendable {
    let name = "upload_file"
    let description = "Upload a file from the user's device to the remote server via SFTP. The file data is provided by the client from the user's selected attachments. Use this when the user attaches files and asks to upload them."

    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "filename": [
                "type": "string",
                "description": "The name of the file to upload (must match one of the user's attached files)",
            ] as [String: String],
            "remote_path": [
                "type": "string",
                "description": "The full destination path on the remote server including filename (e.g. /home/user/docs/report.xlsx)",
            ] as [String: String],
        ] as [String: Any],
        "required": ["filename", "remote_path"],
    ]

    /// 文件上传属于状态变更操作，需用户确认。
    func validateSafety(arguments: [String: Any]) -> SafetyLevel {
        .needsConfirmation
    }

    var supportsStreaming: Bool { true }

    func execute(arguments: [String: Any], sshClient: SSHClientProtocol) async throws -> ToolExecutionResult {
        // 非流式回退：直接整块写入
        let (fileName, remotePath, attachments) = try extractParams(arguments)
        guard let attachment = attachments.first(where: { $0.fileName == fileName }) else {
            return ToolExecutionResult(
                output: "Error: File '\(fileName)' not found in user's attachments. Available files: \(attachments.map(\.fileName).joined(separator: ", "))",
                isSuccess: false
            )
        }

        try await sshClient.sftpWriteFile(path: remotePath, data: attachment.data)
        let size = try await sshClient.sftpFileSize(path: remotePath)
        return ToolExecutionResult(output: "Uploaded '\(fileName)' to \(remotePath) successfully (\(size) bytes)")
    }

    func executeStreaming(
        arguments: [String: Any],
        sshClient: SSHClientProtocol
    ) async throws -> AsyncThrowingStream<String, Error>? {
        let (fileName, remotePath, attachments) = try extractParams(arguments)
        guard let attachment = attachments.first(where: { $0.fileName == fileName }) else {
            return AsyncThrowingStream { continuation in
                continuation.yield("Error: File '\(fileName)' not found in user's attachments. Available files: \(attachments.map(\.fileName).joined(separator: ", "))")
                continuation.finish()
            }
        }

        return AsyncThrowingStream { continuation in
            Task {
                do {
                    let startTime = Date()
                    continuation.yield("Uploading \(fileName) (\(attachment.formattedSize))...")

                    try await sshClient.sftpWriteFileChunked(
                        path: remotePath,
                        data: attachment.data,
                        chunkSize: 256 * 1024
                    ) { bytesWritten, totalBytes in
                        let percent = Int(Double(bytesWritten) / Double(totalBytes) * 100)
                        let elapsed = Date().timeIntervalSince(startTime)
                        let speed = elapsed > 0 ? Double(bytesWritten) / elapsed : 0
                        let speedStr = ByteCountFormatter.string(fromByteCount: Int64(speed), countStyle: .file)
                        continuation.yield("Uploading \(fileName): \(percent)% (\(speedStr)/s)")
                    }

                    let size = try await sshClient.sftpFileSize(path: remotePath)
                    let elapsed = Date().timeIntervalSince(startTime)
                    let speedStr = ByteCountFormatter.string(
                        fromByteCount: Int64(Double(size) / max(elapsed, 0.001)),
                        countStyle: .file
                    )
                    continuation.yield("Uploaded '\(fileName)' to \(remotePath) successfully (\(size) bytes, \(speedStr)/s)")
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// 从 arguments 中提取参数和内部注入的附件数据。
    private func extractParams(_ arguments: [String: Any]) throws -> (String, String, [FileAttachment]) {
        guard let fileName = arguments["filename"] as? String else {
            throw ToolError.missingParameter("filename")
        }
        guard let remotePath = arguments["remote_path"] as? String else {
            throw ToolError.missingParameter("remote_path")
        }
        guard let attachments = arguments["_attachments"] as? [FileAttachment] else {
            throw ToolError.invalidArguments("No file attachments available. The user needs to attach files before uploading.")
        }
        return (fileName, remotePath, attachments)
    }
}
