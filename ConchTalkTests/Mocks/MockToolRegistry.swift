/// 文件说明：MockToolRegistry，测试用工具注册表模拟，支持动态注册与查询。
@testable import ConchTalk
import Foundation

/// MockToolRegistry：
/// 实现 ToolRegistryProtocol 的测试替身，提供动态工具注册与按名称查找。
final class MockToolRegistry: ToolRegistryProtocol, @unchecked Sendable {

    // MARK: - 内部存储

    private var _tools: [ToolProtocol] = []

    // MARK: - ToolRegistryProtocol

    var tools: [ToolProtocol] {
        _tools
    }

    func tool(named name: String) -> ToolProtocol? {
        _tools.first { $0.name == name }
    }

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
                    "parameters": tool.parametersSchema
                ] as [String: Any]
            ]
        }
    }

    // MARK: - 辅助方法

    /// 注册一个工具到注册表。
    func register(_ tool: ToolProtocol) {
        _tools.append(tool)
    }

    /// 清空所有已注册工具。
    func reset() {
        _tools = []
    }
}
