/// 文件说明：RelayMessage，定义 relay WebSocket 消息类型与解析。
import Foundation

/// RelayEvent：从 relay DO 收到的事件。
enum RelayEvent: @unchecked Sendable {
    case connected
    case disconnected
    case assistantText(delta: String)
    case toolCall(id: String, tool: String, args: [String: Any])
    case toolProgress(id: String, stream: String, data: String)
    case toolResult(id: String, exitCode: Int)
    case approvalRequest(id: String, tool: String, args: [String: Any], explanation: String)
    case done
    case error(message: String)
    case daemonStatus(online: Bool)
    case sync(messages: [[String: Any]])
    case acpStarted(sessionID: String)
    case acpData(sessionID: String, stream: String, data: String)
    case acpClosed(sessionID: String)
    case acpError(sessionID: String, error: String)
    case capabilities(agents: [AgentInfo])
    case toolDone(id: String, exitCode: Int, output: String)
    case toolError(id: String, error: String)
    case metrics(cpu: Double, memory: Double)
}

/// RelayMessage：解析 DO 下发的 JSON 消息。
enum RelayMessage {
    nonisolated static func parse(from data: Data) -> RelayEvent? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            return nil
        }

        switch type {
        case "assistant_text":
            return .assistantText(delta: json["delta"] as? String ?? "")
        case "tool_call":
            return .toolCall(
                id: json["id"] as? String ?? "",
                tool: json["tool"] as? String ?? "",
                args: json["args"] as? [String: Any] ?? [:]
            )
        case "tool_progress":
            return .toolProgress(
                id: json["id"] as? String ?? "",
                stream: json["stream"] as? String ?? "",
                data: json["data"] as? String ?? ""
            )
        case "tool_result":
            return .toolResult(
                id: json["id"] as? String ?? "",
                exitCode: json["exit_code"] as? Int ?? -1
            )
        case "approval_request":
            return .approvalRequest(
                id: json["id"] as? String ?? "",
                tool: json["tool"] as? String ?? "",
                args: json["args"] as? [String: Any] ?? [:],
                explanation: json["explanation"] as? String ?? ""
            )
        case "done":
            return .done
        case "error":
            return .error(message: json["message"] as? String ?? "Unknown error")
        case "status":
            return .daemonStatus(online: (json["daemon"] as? String) == "online")
        case "sync":
            return .sync(messages: json["messages"] as? [[String: Any]] ?? [])
        case "acp_started":
            return .acpStarted(sessionID: json["session_id"] as? String ?? "")
        case "acp_data":
            return .acpData(
                sessionID: json["session_id"] as? String ?? "",
                stream: json["stream"] as? String ?? "stdout",
                data: json["data"] as? String ?? ""
            )
        case "acp_closed":
            return .acpClosed(sessionID: json["session_id"] as? String ?? "")
        case "acp_error":
            return .acpError(
                sessionID: json["session_id"] as? String ?? "",
                error: json["error"] as? String ?? "Unknown ACP error"
            )
        case "capabilities":
            let rawAgents = json["agents"] as? [[String: Any]] ?? []
            let agents = rawAgents.compactMap { raw -> AgentInfo? in
                guard let typeStr = raw["type"] as? String,
                      let agentType = AgentType(rawValue: typeStr) else { return nil }
                let path = raw["path"] as? String ?? typeStr
                let version = raw["version"] as? String
                return AgentInfo(type: agentType, path: path, version: version)
            }
            return .capabilities(agents: agents)
        case "tool_done":
            return .toolDone(
                id: json["id"] as? String ?? "",
                exitCode: json["exit_code"] as? Int ?? 0,
                output: json["output"] as? String ?? ""
            )
        case "tool_error":
            return .toolError(
                id: json["id"] as? String ?? "",
                error: json["error"] as? String ?? "Unknown error"
            )
        case "ping":
            if let m = json["metrics"] as? [String: Any] {
                return .metrics(
                    cpu: m["cpu"] as? Double ?? 0,
                    memory: m["memory"] as? Double ?? 0
                )
            }
            return nil
        case "pong":
            return nil
        default:
            return nil
        }
    }
}
