import Foundation

/// The result of executing a tool.
nonisolated struct ToolExecutionResult: Sendable {
    let output: String
    let isSuccess: Bool

    init(output: String, isSuccess: Bool = true) {
        self.output = output
        self.isSuccess = isSuccess
    }
}
