import Foundation

struct ManageServiceTool: ToolProtocol {
    let name = "manage_service"
    let description = "Manage systemd services on the remote server. Can check status, view logs, start, stop, or restart services."

    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "service": [
                "type": "string",
                "description": "Name of the systemd service (e.g. 'nginx', 'docker', 'sshd')",
            ] as [String: String],
            "action": [
                "type": "string",
                "enum": ["status", "logs", "start", "stop", "restart", "enable", "disable"],
                "description": "Action to perform on the service",
            ] as [String: Any],
            "log_lines": [
                "type": "integer",
                "description": "Number of log lines to retrieve (only for 'logs' action). Defaults to 50.",
            ] as [String: String],
            "explanation": [
                "type": "string",
                "description": "A brief explanation of why you are managing this service",
            ] as [String: String],
        ] as [String: Any],
        "required": ["service", "action", "explanation"],
    ]

    private static let safeActions: Set<String> = ["status", "logs"]

    func validateSafety(arguments: [String: Any]) -> SafetyLevel {
        let action = arguments["action"] as? String ?? ""
        return Self.safeActions.contains(action) ? .safe : .needsConfirmation
    }

    func execute(arguments: [String: Any], sshClient: SSHClientProtocol) async throws -> ToolExecutionResult {
        guard let service = arguments["service"] as? String else {
            throw ToolError.missingParameter("service")
        }
        guard let action = arguments["action"] as? String else {
            throw ToolError.missingParameter("action")
        }

        let command: String
        switch action {
        case "status":
            command = "systemctl status \(shellEscape(service))"
        case "logs":
            let lines = arguments["log_lines"] as? Int ?? 50
            command = "journalctl -u \(shellEscape(service)) -n \(lines) --no-pager"
        case "start", "stop", "restart", "enable", "disable":
            command = "sudo systemctl \(action) \(shellEscape(service))"
        default:
            throw ToolError.invalidArguments("Unknown action: \(action)")
        }

        let output = try await sshClient.execute(command: command)
        return ToolExecutionResult(output: output)
    }
}
