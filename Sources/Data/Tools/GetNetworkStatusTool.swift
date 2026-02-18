import Foundation

struct GetNetworkStatusTool: ToolProtocol {
    let name = "get_network_status"
    let description = "Get network status information from the remote server, including interfaces, connections, and ports."

    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "category": [
                "type": "string",
                "enum": ["interfaces", "connections", "ports", "all"],
                "description": "Category of network info to retrieve. Defaults to 'all'.",
            ] as [String: Any],
            "explanation": [
                "type": "string",
                "description": "A brief explanation of why you need the network status",
            ] as [String: String],
        ] as [String: Any],
        "required": ["explanation"],
    ]

    func validateSafety(arguments: [String: Any]) -> SafetyLevel {
        .safe
    }

    func execute(arguments: [String: Any], sshClient: SSHClientProtocol) async throws -> ToolExecutionResult {
        let category = arguments["category"] as? String ?? "all"

        let command: String
        switch category {
        case "interfaces":
            command = "ip addr show 2>/dev/null || ifconfig"
        case "connections":
            command = "ss -tunap 2>/dev/null || netstat -tunap 2>/dev/null"
        case "ports":
            command = "ss -tlnp 2>/dev/null || netstat -tlnp 2>/dev/null"
        default: // "all"
            command = """
                echo '=== Interfaces ===' && (ip addr show 2>/dev/null || ifconfig) && \
                echo '\\n=== Listening Ports ===' && (ss -tlnp 2>/dev/null || netstat -tlnp 2>/dev/null)
                """
        }

        let output = try await sshClient.execute(command: command)
        return ToolExecutionResult(output: output)
    }
}
