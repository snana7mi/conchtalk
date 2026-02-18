import Foundation

struct ListDirectoryTool: ToolProtocol {
    let name = "list_directory"
    let description = "List files and directories at the specified path on the remote server."

    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "path": [
                "type": "string",
                "description": "Absolute path to the directory to list. Defaults to current directory if omitted.",
            ] as [String: String],
            "show_hidden": [
                "type": "boolean",
                "description": "Whether to show hidden files (dotfiles). Defaults to false.",
            ] as [String: String],
            "long_format": [
                "type": "boolean",
                "description": "Whether to use long format (permissions, size, date). Defaults to true.",
            ] as [String: String],
            "explanation": [
                "type": "string",
                "description": "A brief explanation of why you are listing this directory",
            ] as [String: String],
        ] as [String: [String: String]],
        "required": ["explanation"],
    ]

    func validateSafety(arguments: [String: Any]) -> SafetyLevel {
        .safe
    }

    func execute(arguments: [String: Any], sshClient: SSHClientProtocol) async throws -> ToolExecutionResult {
        let path = (arguments["path"] as? String) ?? "."
        let showHidden = arguments["show_hidden"] as? Bool ?? false
        let longFormat = arguments["long_format"] as? Bool ?? true

        var flags = ""
        if longFormat { flags += "l" }
        if showHidden { flags += "a" }
        flags += "h" // human-readable sizes

        let command = "ls -\(flags) \(shellEscape(path))"
        let output = try await sshClient.execute(command: command)
        return ToolExecutionResult(output: output)
    }
}
