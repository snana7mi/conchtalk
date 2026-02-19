/// 文件说明：GetSystemInfoTool，提供远端主机 CPU/内存/磁盘/系统信息采集能力。
import Foundation

/// GetSystemInfoTool：
/// 面向诊断场景输出系统关键指标，可按类别查询或一次性返回全量快照。
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

    /// 系统信息采集属于只读操作，可直接执行。
    func validateSafety(arguments: [String: Any]) -> SafetyLevel {
        .safe
    }

    /// 根据 `category` 选择采集命令并返回结果。
    /// - Parameters:
    ///   - arguments: 可选 `category`（`all/cpu/memory/disk/os`）。
    ///   - sshClient: SSH 执行客户端。
    /// - Returns: 对应系统信息文本。
    /// - Throws: 远端命令执行失败时抛出。
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
