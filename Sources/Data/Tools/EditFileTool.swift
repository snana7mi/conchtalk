/// 文件说明：EditFileTool，提供远端文件局部编辑能力，避免全量重写浪费 token。
import Foundation

/// EditFileTool：
/// 对远端文件进行精确的局部替换，仅传输需要修改的片段，
/// 大幅减少 token 消耗，适用于小范围代码修改场景。
nonisolated struct EditFileTool: ToolProtocol, @unchecked Sendable {
    let name = "edit_file"
    let description = "Prefer this over execute_ssh_command with sed. Edit a file by replacing specific text. More efficient than write_file for small changes — only send the part that needs to change."

    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "path": [
                "type": "string",
                "description": "Absolute path to the file to edit",
            ] as [String: String],
            "old_text": [
                "type": "string",
                "description": "The exact text to find and replace. Must match the file content exactly (including whitespace and indentation).",
            ] as [String: String],
            "new_text": [
                "type": "string",
                "description": "The replacement text. Use empty string to delete the matched text.",
            ] as [String: String],
            "explanation": [
                "type": "string",
                "description": "A brief explanation of what you are editing and why",
            ] as [String: String],
        ] as [String: [String: String]],
        "required": ["path", "old_text", "new_text", "explanation"],
    ]

    /// 编辑文件属于状态变更操作，默认要求用户确认后执行。
    func validateSafety(arguments: [String: Any]) -> SafetyLevel {
        .needsConfirmation
    }

    /// 通过 sed 或 awk 在远端文件中执行精确文本替换。
    /// 实现策略：先用 grep 确认匹配唯一，再用 Python/perl 执行替换。
    /// - Parameters:
    ///   - arguments: 需包含 `path`、`old_text`、`new_text`。
    ///   - sshClient: SSH 执行客户端。
    /// - Returns: 编辑成功提示。
    /// - Throws: 参数缺失、匹配不到或匹配多处时抛出。
    func execute(arguments: [String: Any], sshClient: SSHClientProtocol) async throws -> ToolExecutionResult {
        guard let path = arguments["path"] as? String else {
            throw ToolError.missingParameter("path")
        }
        guard let oldText = arguments["old_text"] as? String else {
            throw ToolError.missingParameter("old_text")
        }
        guard let newText = arguments["new_text"] as? String else {
            throw ToolError.missingParameter("new_text")
        }

        let data = try await sshClient.sftpReadFile(path: path)
        guard var content = String(data: data, encoding: .utf8) else {
            throw ToolError.executionFailed("File is not valid UTF-8")
        }

        let matchCount = content.components(separatedBy: oldText).count - 1
        if matchCount == 0 {
            throw ToolError.executionFailed("old_text not found in file")
        }
        if matchCount > 1 {
            throw ToolError.executionFailed("old_text matches \(matchCount) locations, must be unique")
        }
        guard let range = content.range(of: oldText) else {
            throw ToolError.executionFailed("old_text not found in file")
        }
        content.replaceSubrange(range, with: newText)
        try await sshClient.sftpWriteFile(path: path, data: Data(content.utf8))

        return ToolExecutionResult(output: "Edited \(path) successfully")
    }
}
