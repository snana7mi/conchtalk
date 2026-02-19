/// 文件说明：ToolRegistryProtocol，定义工具注册表的查询与导出契约。
import Foundation

/// ToolRegistryProtocol：
/// 约束工具注册中心能力，供上层按名称查找工具并导出 OpenAI `tools` 定义。
protocol ToolRegistryProtocol: Sendable {
    /// 当前已注册工具列表。
    var tools: [ToolProtocol] { get }
    /// 按工具名查找工具实现。
    /// - Parameter name: 工具名称。
    /// - Returns: 匹配到的工具；不存在时返回 `nil`。
    func tool(named name: String) -> ToolProtocol?
    /// 导出符合 OpenAI Chat Completions 协议的 `tools` 数组。
    /// - Returns: 可直接拼入请求体的工具定义列表。
    func openAIToolDefinitions() -> [[String: Any]]
}
