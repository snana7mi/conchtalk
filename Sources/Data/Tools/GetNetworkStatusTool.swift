/// 文件说明：GetNetworkStatusTool，提供远端网络接口、连接与端口状态查询。
import Foundation

/// GetNetworkStatusTool：
/// 聚合网络诊断常用命令（`ip/ifconfig/ss/netstat`），
/// 支持按接口、连接、端口或全量信息查询。
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

    /// 网络状态查询属于只读操作，可直接执行。
    func validateSafety(arguments: [String: Any]) -> SafetyLevel {
        .safe
    }

    /// 根据 `category` 构建网络诊断命令并返回输出。
    /// - Parameters:
    ///   - arguments: 可选 `category`（`interfaces/connections/ports/all`）。
    ///   - sshClient: SSH 执行客户端。
    /// - Returns: 网络状态文本输出。
    /// - Throws: 远端命令执行失败时抛出。
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
