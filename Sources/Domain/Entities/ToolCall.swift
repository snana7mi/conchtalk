/// 文件说明：ToolCall，定义模型函数调用请求的领域实体模型。
import Foundation

/// ToolCall：
/// 表示模型请求执行某个工具时的结构化数据，
/// 可挂载在消息中并持久化到本地存储。
nonisolated struct ToolCall: Codable, Sendable {
    let id: String              // OpenAI tool_call ID (e.g. "call_abc123")
    let toolName: String        // "execute_ssh_command", "read_file", etc.
    let argumentsJSON: Data     // Raw JSON arguments, each tool decodes its own
    let explanation: String     // Human-readable explanation from AI

    /// 将原始参数 JSON 解码为字典，供工具分发层使用。
    /// - Returns: 参数字典。
    /// - Throws: 当 JSON 非对象结构或解码失败时抛出 `ToolError.invalidArguments`。
    func decodedArguments() throws -> [String: Any] {
        guard let dict = try JSONSerialization.jsonObject(with: argumentsJSON) as? [String: Any] else {
            throw ToolError.invalidArguments("Failed to decode arguments as JSON object")
        }
        return dict
    }
}
