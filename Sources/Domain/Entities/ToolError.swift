/// 文件说明：ToolError，定义工具调用与执行过程中的标准错误模型。
import Foundation

/// ToolError：表示工具分发、参数校验与执行阶段的失败原因。
enum ToolError: LocalizedError {
    case toolNotFound(String)
    case invalidArguments(String)
    case executionFailed(String)
    case missingParameter(String)

    /// 适用于 UI 或日志展示的错误说明。
    var errorDescription: String? {
        switch self {
        case .toolNotFound(let name): return "Tool not found: \(name)"
        case .invalidArguments(let detail): return "Invalid arguments: \(detail)"
        case .executionFailed(let detail): return "Tool execution failed: \(detail)"
        case .missingParameter(let name): return "Missing required parameter: \(name)"
        }
    }
}
