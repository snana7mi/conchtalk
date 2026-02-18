import Foundation

final class ToolRegistry: ToolRegistryProtocol, @unchecked Sendable {
    private let _tools: [ToolProtocol]
    private let toolMap: [String: ToolProtocol]

    var tools: [ToolProtocol] { _tools }

    init(tools: [ToolProtocol]) {
        self._tools = tools
        var map: [String: ToolProtocol] = [:]
        for tool in tools {
            map[tool.name] = tool
        }
        self.toolMap = map
    }

    func tool(named name: String) -> ToolProtocol? {
        toolMap[name]
    }

    func openAIToolDefinitions() -> [[String: Any]] {
        _tools.map { tool in
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
