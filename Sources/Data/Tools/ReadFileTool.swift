import Foundation

struct ReadFileTool: ToolProtocol {
    let name = "read_file"
    let description = "Read the contents of a file on the remote server. Supports reading entire files or specific line ranges."

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
            "explanation": [
                "type": "string",
                "description": "A brief explanation of why you are reading this file",
            ] as [String: String],
        ] as [String: [String: String]],
        "required": ["path", "explanation"],
    ]

    func validateSafety(arguments: [String: Any]) -> SafetyLevel {
        .safe
    }

    func execute(arguments: [String: Any], sshClient: SSHClientProtocol) async throws -> ToolExecutionResult {
        guard let path = arguments["path"] as? String else {
            throw ToolError.missingParameter("path")
        }

        var command: String
        if let startLine = arguments["start_line"] as? Int,
           let endLine = arguments["end_line"] as? Int {
            command = "sed -n '\(startLine),\(endLine)p' \(shellEscape(path))"
        } else if let startLine = arguments["start_line"] as? Int {
            command = "tail -n +\(startLine) \(shellEscape(path))"
        } else if let endLine = arguments["end_line"] as? Int {
            command = "head -n \(endLine) \(shellEscape(path))"
        } else {
            command = "cat \(shellEscape(path))"
        }

        let output = try await sshClient.execute(command: command)
        return ToolExecutionResult(output: output)
    }
}
