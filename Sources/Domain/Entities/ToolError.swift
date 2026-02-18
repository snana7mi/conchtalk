import Foundation

enum ToolError: LocalizedError {
    case toolNotFound(String)
    case invalidArguments(String)
    case executionFailed(String)
    case missingParameter(String)

    var errorDescription: String? {
        switch self {
        case .toolNotFound(let name): return "Tool not found: \(name)"
        case .invalidArguments(let detail): return "Invalid arguments: \(detail)"
        case .executionFailed(let detail): return "Tool execution failed: \(detail)"
        case .missingParameter(let name): return "Missing required parameter: \(name)"
        }
    }
}
