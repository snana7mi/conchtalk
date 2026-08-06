/// 文件说明：SuggestAgentConnectionTool，AI 建议连接编码代理时的客户端拦截工具。
import Foundation

/// SuggestAgentConnectionTool：
/// 当 AI 判断用户需要连接编码代理时，调用此工具触发客户端弹出确认弹窗。
/// 用户确认后进入直连对话模式。
/// 该工具不直接执行，而是在 agentic loop 中被拦截处理。
nonisolated struct SuggestAgentConnectionTool: ToolProtocol, @unchecked Sendable {
    let name = "suggest_agent_connection"
    let description = """
        Connect to a coding agent. Call this tool IMMEDIATELY when the user asks to use an agent — \
        do NOT run any exploratory commands (no checking configs, versions, directories, etc.) beforehand. \
        This opens a confirmation dialog for the user to approve direct connection. \
        IMPORTANT: Do NOT use for Docker operations (docker exec, etc.) — use execute_ssh_command instead. \
        Working directory handling for coding agents (opencode, gemini, kimi, qwen, claude, codex): \
        (1) If the user specified a path, pass it as 'cwd'. \
        (2) Otherwise, call 'list_directory' on the home directory ONCE, then pass the result as 'directories'. \
        Do NOT run any other commands — just list_directory then this tool. \
        For non-coding agents (openclaw), omit cwd and directories. \
        If the agent was just installed, call 'refresh_capabilities' first. \
        For retries, call again with the same agent. \
        This is the ONLY way to connect — never suggest SSH commands or CLI invocation.
        """

    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "agent": [
                "type": "string",
                "description": "Preferred agent type: 'opencode', 'gemini', 'kimi', 'openclaw', 'qwen', 'claude', or 'codex' (optional, user can pick from available agents)"
            ] as [String: String],
            "reason": [
                "type": "string",
                "description": "Brief reason for suggesting agent connection, in the user's language"
            ] as [String: String],
            "cwd": [
                "type": "string",
                "description": "Working directory path extracted from user's conversation context (absolute path on the remote server). Only for coding agents."
            ] as [String: String],
            "directories": [
                "type": "array",
                "items": ["type": "string"] as [String: String],
                "description": "Directory names under the home directory, obtained from list_directory tool. Provided when user did not specify a path, so the client can show a directory browser. Only for coding agents."
            ] as [String: Any],
            "home_path": [
                "type": "string",
                "description": "The home directory path used when calling list_directory to obtain the directories list. Required when 'directories' is provided."
            ] as [String: String],
        ] as [String: Any],
        "required": [] as [String]
    ]

    /// suggest_agent_connection 始终安全（由客户端拦截，不实际执行远端命令）。
    func validateSafety(arguments: [String: Any]) -> SafetyLevel {
        .safe
    }

    /// 此工具在 agentic loop 中被拦截，不应直接执行。
    func execute(arguments: [String: Any], sshClient: SSHClientProtocol) async throws -> ToolExecutionResult {
        ToolExecutionResult(output: "ERROR: suggest_agent_connection should be intercepted by the client, not executed directly.", isSuccess: false)
    }
}
