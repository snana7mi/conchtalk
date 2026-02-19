/// 文件说明：ManageServiceTool，封装 systemd 服务查询与运维操作。
import Foundation

/// ManageServiceTool：
/// 统一封装 `systemctl` 与 `journalctl` 常见操作，
/// 对变更类动作（start/stop/restart/enable/disable）要求确认执行。
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

    /// 根据动作类型评估安全级别。
    /// - Note: `status/logs` 属于只读；其余动作为状态变更。
    func validateSafety(arguments: [String: Any]) -> SafetyLevel {
        let action = arguments["action"] as? String ?? ""
        return Self.safeActions.contains(action) ? .safe : .needsConfirmation
    }

    /// 执行服务管理动作并返回命令输出。
    /// - Parameters:
    ///   - arguments: 需包含 `service` 与 `action`。
    ///   - sshClient: SSH 执行客户端。
    /// - Returns: 服务状态、日志或执行结果文本。
    /// - Throws: 参数缺失、动作非法或远端执行失败时抛出。
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
