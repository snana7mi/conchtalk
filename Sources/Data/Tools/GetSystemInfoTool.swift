import Foundation

struct GetSystemInfoTool: ToolProtocol {
    let name = "get_system_info"
    let description = "Get system information including CPU, memory, disk usage, and OS details from the remote server."

    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "category": [
                "type": "string",
                "enum": ["all", "cpu", "memory", "disk", "os"],
                "description": "Category of system info to retrieve. Defaults to 'all'.",
            ] as [String: Any],
            "explanation": [
                "type": "string",
                "description": "A brief explanation of why you need this system info",
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
        case "cpu":
            command = "nproc && cat /proc/cpuinfo | grep 'model name' | head -1 && uptime"
        case "memory":
            command = "free -h"
        case "disk":
            command = "df -h"
        case "os":
            command = "uname -a && cat /etc/os-release 2>/dev/null || sw_vers 2>/dev/null || echo 'Unknown OS'"
        default: // "all"
            command = """
                echo '=== OS ===' && uname -a && \
                echo '\\n=== CPU ===' && nproc && uptime && \
                echo '\\n=== Memory ===' && free -h && \
                echo '\\n=== Disk ===' && df -h
                """
        }

        let output = try await sshClient.execute(command: command)
        return ToolExecutionResult(output: output)
    }
}
