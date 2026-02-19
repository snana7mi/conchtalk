import Foundation

enum StreamingDelta: Sendable {
    case reasoning(String)   // Reasoning/thinking text increment
    case content(String)     // Reply text increment
    case toolCall(ToolCall)  // Complete tool call
    case done
    case error(Error)
}
