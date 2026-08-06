/// 文件说明：ToolDisplayInfo，统一管理工具的展示元数据（图标、颜色）。
import SwiftUI

/// ToolDisplayInfo：
/// 集中管理所有工具的 SF Symbol 图标和主题色。
/// 消除 CommandDetailView、MessageBubbleView、AgentStreamView 中散落的工具名 switch。
struct ToolDisplayInfo: Sendable {
    let iconName: String
    let color: Color

    /// 根据工具名精确匹配。未知工具返回默认值。
    static func info(for toolName: String) -> ToolDisplayInfo {
        switch toolName {
        case "execute_ssh_command":      return ToolDisplayInfo(iconName: "terminal", color: .green)
        case "read_file":                return ToolDisplayInfo(iconName: "doc.text", color: .green)
        case "write_file":               return ToolDisplayInfo(iconName: "doc.text.fill", color: .orange)
        case "suggest_agent_connection": return ToolDisplayInfo(iconName: "bolt.fill", color: .blue)
        default:                         return ToolDisplayInfo(iconName: "wrench", color: .teal)
        }
    }

    /// 子串模糊匹配，用于 Agent 模式下的非标准工具名。
    static func fuzzyInfo(for toolName: String) -> ToolDisplayInfo {
        if toolName.contains("read") {
            return ToolDisplayInfo(iconName: "doc.text", color: .green)
        } else if toolName.contains("write") || toolName.contains("edit") {
            return ToolDisplayInfo(iconName: "doc.text.fill", color: .orange)
        } else if toolName.contains("list") || toolName.contains("directory") {
            return ToolDisplayInfo(iconName: "folder", color: .green)
        } else if toolName.contains("search") || toolName.contains("grep") {
            return ToolDisplayInfo(iconName: "magnifyingglass", color: .blue)
        } else if toolName.contains("run") || toolName.contains("exec") || toolName.contains("bash") {
            return ToolDisplayInfo(iconName: "terminal", color: .green)
        }
        return ToolDisplayInfo(iconName: "wrench", color: .teal)
    }

    /// 需要参数判断的 statusColor（特殊情况）。
    static func statusColor(for toolName: String, args: [String: Any]?) -> Color {
        switch toolName {
        case "execute_ssh_command":
            let isDestructive = args?["is_destructive"] as? Bool ?? false
            return isDestructive ? .orange : .green
        case "write_file":
            return .orange
        case "suggest_agent_connection":
            return .blue
        default:
            return .green
        }
    }
}
