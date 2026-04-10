/// 文件说明：ToolRegistry，负责工具注册、按名查找与 OpenAI 工具定义导出。
import Foundation

/// ToolRegistry：
/// 工具注册中心实现，内部维护工具数组与名称索引，
/// 供用例层高效查询工具并构建模型函数调用配置。
nonisolated final class ToolRegistry: ToolRegistryProtocol, @unchecked Sendable {
    private let _tools: [ToolProtocol]
    private let toolMap: [String: ToolProtocol]

    var tools: [ToolProtocol] { _tools }

    /// 初始化注册表并构建名称到工具实例的映射表。
    /// - Parameter tools: 需要注册的工具列表。
    init(tools: [ToolProtocol]) {
        self._tools = tools
        var map: [String: ToolProtocol] = [:]
        for tool in tools {
            map[tool.name] = tool
        }
        self.toolMap = map
    }

    /// 按名称查找工具实现。
    /// - Parameter name: 工具名。
    /// - Returns: 命中的工具实例；不存在则为 `nil`。
    func tool(named name: String) -> ToolProtocol? {
        toolMap[name]
    }

    /// 生成符合 OpenAI `tools` 协议的定义数组（带服务器能力过滤）。
    /// 仅在代理探测已完成且无可用编码代理时，排除 `suggest_agent_connection` 工具定义。
    /// 探测未完成时保留所有工具，避免误过滤。
    func openAIToolDefinitions(capabilities: ServerCapabilities) -> [[String: Any]] {
        _tools.filter { tool in
            if tool.name == "suggest_agent_connection",
               capabilities.agentDetectionCompleted {
                return !capabilities.availableAgents.isEmpty
            }
            return true
        }.map { tool in
            [
                "type": "function",
                "function": [
                    "name": tool.name,
                    "description": tool.description,
                    "parameters": tool.parametersSchema,
                ] as [String: Any],
            ] as [String: Any]
        }
    }

}
