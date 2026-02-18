import Foundation

/// Registry that holds all available tools.
protocol ToolRegistryProtocol: Sendable {
    /// All registered tools.
    var tools: [ToolProtocol] { get }
    /// Look up a tool by name.
    func tool(named name: String) -> ToolProtocol?
    /// Generate the OpenAI `tools` array for the chat/completions request.
    func openAIToolDefinitions() -> [[String: Any]]
}
