/// 文件说明：SystemProfile，描述服务器系统环境探测结果。
import Foundation

/// SystemProfile：
/// 连接时自动探测的服务器环境快照，包括操作系统、包管理器和可用 ACP 代理。
/// 持久化到 SwiftData，注入 AI 上下文避免对话中重复探测。
/// 通用工具（curl/git/docker 等）不再预探测，由 AI 按需发现。
nonisolated struct SystemProfile: Codable, Sendable {
    let serverID: UUID
    let detectedAt: Date
    let osInfo: String
    let packageManager: String?
    let installedTools: [ToolInfo]

    /// ToolInfo：单个工具的探测结果。
    nonisolated struct ToolInfo: Codable, Sendable {
        let name: String
        let available: Bool
        let version: String?
        let path: String?
    }

    /// 需要探测的 ACP 代理二进制名（通用工具不再预探测，由 AI 按需发现）。
    static let agentToolNames: [String] = AgentType.allCases.map(\.binaryName)

    /// ACP 兼容 AI Agent 的二进制名集合（用于 formattedContext 分类展示）。
    private static let agentBinaryNames: Set<String> = Set(AgentType.allCases.map(\.binaryName))

    /// 格式化为紧凑的 AI 上下文字符串。
    /// 只包含 OS、包管理器和可用 ACP 代理；通用工具不再列出。
    func formattedContext() -> String {
        let availableAgents = installedTools
            .filter { Self.agentBinaryNames.contains($0.name) && $0.available }
            .map { agent in
                if let ver = agent.version, !ver.isEmpty {
                    return "\(agent.name) (\(ver))"
                }
                return agent.name
            }
            .joined(separator: ", ")

        var lines: [String] = ["## Server System Profile (auto-detected)"]
        if let pm = packageManager {
            lines.append("Package Manager: \(pm)")
        }
        if !availableAgents.isEmpty {
            lines.append("ACP Agents: \(availableAgents)")
        }
        return lines.joined(separator: "\n")
    }

    /// 从已探测工具信息中派生运行时能力，避免重复 SSH 探测。
    func toCapabilities() -> ServerCapabilities {
        let agents = installedTools
            .filter { Self.agentBinaryNames.contains($0.name) && $0.available }
            .compactMap { tool -> AgentInfo? in
                guard let type = AgentType(rawValue: tool.name) else { return nil }
                return AgentInfo(type: type, path: tool.path ?? tool.name, version: tool.version)
            }
        var caps = ServerCapabilities()
        caps.availableAgents = agents
        caps.agentDetectionCompleted = true
        return caps
    }
}
