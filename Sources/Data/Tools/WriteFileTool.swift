import Foundation

struct WriteFileTool: ToolProtocol {
    let name = "write_file"
    let description = "Write content to a file on the remote server. Can overwrite or append."

    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "path": [
                "type": "string",
                "description": "Absolute path to the file to write",
            ] as [String: String],
            "content": [
                "type": "string",
                "description": "The content to write to the file",
            ] as [String: String],
            "append": [
                "type": "boolean",
                "description": "If true, append to the file instead of overwriting. Defaults to false.",
            ] as [String: String],
            "explanation": [
                "type": "string",
                "description": "A brief explanation of what you are writing and why",
            ] as [String: String],
        ] as [String: [String: String]],
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

        let append = arguments["append"] as? Bool ?? false
        let op = append ? ">>" : ">"
        // Use heredoc for safe content transfer
        let command = "cat <<'CONCHTALK_EOF' \(op) \(shellEscape(path))\n\(content)\nCONCHTALK_EOF"

        let output = try await sshClient.execute(command: command)
        let verb = append ? "Appended to" : "Written to"
        let result = output.isEmpty ? "\(verb) \(path) successfully" : output
        return ToolExecutionResult(output: result)
    }
}
