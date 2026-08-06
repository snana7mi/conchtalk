/// 文件说明：MockTool，测试用 AI 工具模拟，支持配置名称、安全级别、执行结果与调用计数。
@testable import ConchTalk
import Foundation

/// MockTool：
/// 实现 ToolProtocol 的测试替身，支持灵活配置执行行为与安全分级。
final class MockTool: ToolProtocol, @unchecked Sendable {

    // MARK: - 可配置属性

    var name: String
    var description: String
    var parametersSchema: [String: Any]
    var safetyLevel: SafetyLevel
    var executeResult: ToolExecutionResult
    var executeError: Error?
    var _supportsStreaming: Bool = false
    var streamingOutput: [String] = []
    var streamingError: Error?

    // MARK: - 调用记录

    private(set) var executeCalled = 0
    private(set) var executeStreamingCalled = 0
    private(set) var validateSafetyCalled = 0
    private(set) var lastArguments: [String: Any]?

    // MARK: - 初始化

    init(
        name: String = "mock_tool",
        description: String = "A mock tool for testing",
        parametersSchema: [String: Any] = ["type": "object", "properties": [:] as [String: Any]],
        safetyLevel: SafetyLevel = .safe,
        executeResult: ToolExecutionResult = ToolExecutionResult(output: "mock output")
    ) {
        self.name = name
        self.description = description
        self.parametersSchema = parametersSchema
        self.safetyLevel = safetyLevel
        self.executeResult = executeResult
    }

    // MARK: - ToolProtocol

    func validateSafety(arguments: [String: Any]) -> SafetyLevel {
        validateSafetyCalled += 1
        lastArguments = arguments
        return safetyLevel
    }

    func execute(arguments: [String: Any], sshClient: SSHClientProtocol) async throws -> ToolExecutionResult {
        executeCalled += 1
        lastArguments = arguments
        if let error = executeError { throw error }
        return executeResult
    }

    var supportsStreaming: Bool {
        _supportsStreaming
    }

    func executeStreaming(arguments: [String: Any], sshClient: SSHClientProtocol) async throws -> AsyncThrowingStream<String, Error>? {
        executeStreamingCalled += 1
        lastArguments = arguments
        guard _supportsStreaming else { return nil }
        let output = streamingOutput
        let error = streamingError
        return AsyncThrowingStream { continuation in
            Task {
                for chunk in output {
                    continuation.yield(chunk)
                }
                if let error {
                    continuation.finish(throwing: error)
                } else {
                    continuation.finish()
                }
            }
        }
    }

    // MARK: - 辅助方法

    func reset() {
        executeCalled = 0
        executeStreamingCalled = 0
        validateSafetyCalled = 0
        lastArguments = nil
        executeError = nil
    }
}
