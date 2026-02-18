import Foundation

struct GetProcessListTool: ToolProtocol {
    let name = "get_process_list"
    let description = "List running processes on the remote server, optionally filtered by name."

    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "filter": [
                "type": "string",
                "description": "Optional process name filter. Only processes matching this string will be shown.",
            ] as [String: String],
            "sort_by": [
                "type": "string",
                "enum": ["cpu", "memory", "pid"],
                "description": "Sort processes by CPU usage, memory usage, or PID. Defaults to 'cpu'.",
            ] as [String: Any],
            "limit": [
                "type": "integer",
                "description": "Maximum number of processes to return. Defaults to 20.",
            ] as [String: String],
            "explanation": [
                "type": "string",
                "description": "A brief explanation of why you need the process list",
            ] as [String: String],
        ] as [String: Any],
        "required": ["explanation"],
    ]

    func validateSafety(arguments: [String: Any]) -> SafetyLevel {
        .safe
    }

    func execute(arguments: [String: Any], sshClient: SSHClientProtocol) async throws -> ToolExecutionResult {
        let filter = arguments["filter"] as? String
        let sortBy = arguments["sort_by"] as? String ?? "cpu"
        let limit = arguments["limit"] as? Int ?? 20

        let sortFlag: String
        switch sortBy {
        case "memory": sortFlag = "--sort=-%mem"
        case "pid": sortFlag = "--sort=pid"
        default: sortFlag = "--sort=-%cpu"
        }

        var command = "ps aux \(sortFlag) | head -n \(limit + 1)"
        if let filter, !filter.isEmpty {
            command = "ps aux \(sortFlag) | head -1; ps aux \(sortFlag) | grep \(shellEscape(filter)) | grep -v grep | head -n \(limit)"
        }

        let output = try await sshClient.execute(command: command)
        return ToolExecutionResult(output: output)
    }
}
