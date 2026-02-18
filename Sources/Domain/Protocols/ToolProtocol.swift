import Foundation

/// Safety level for tool execution.
enum SafetyLevel: Sendable {
    case safe               // Auto-execute without user confirmation
    case needsConfirmation  // Show confirmation dialog before executing
    case forbidden          // Block execution entirely
}

/// Protocol for all tools that the AI can invoke.
protocol ToolProtocol: Sendable {
    /// Unique tool name, e.g. "execute_ssh_command"
    var name: String { get }
    /// Human-readable description for the AI system prompt
    var description: String { get }
    /// OpenAI function-calling JSON schema for parameters
    var parametersSchema: [String: Any] { get }
    /// Validate the safety level of this invocation
    func validateSafety(arguments: [String: Any]) -> SafetyLevel
    /// Execute the tool with the given arguments
    func execute(arguments: [String: Any], sshClient: SSHClientProtocol) async throws -> ToolExecutionResult
}
