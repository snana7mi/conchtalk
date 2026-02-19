/// 文件说明：GetProcessListTool，提供远端进程列表查询与筛选能力。
import Foundation

/// GetProcessListTool：
/// 通过 `ps` 获取进程视图，支持按 CPU/内存/PID 排序并按关键字过滤，
/// 适用于性能排查与服务定位场景。
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

    /// 进程列表查询为只读操作，可直接执行。
    func validateSafety(arguments: [String: Any]) -> SafetyLevel {
        .safe
    }

    /// 按排序与过滤条件构建进程查询命令。
    /// - Parameters:
    ///   - arguments: 可选 `filter`、`sort_by`、`limit`。
    ///   - sshClient: SSH 执行客户端。
    /// - Returns: 进程列表文本。
    /// - Throws: 远端命令执行失败时抛出。
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
