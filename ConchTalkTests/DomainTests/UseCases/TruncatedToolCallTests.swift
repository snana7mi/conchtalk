/// 文件说明：TruncatedToolCallTests，验证被 max_tokens 截断的工具调用不会执行，而是把原因回填给模型。
import Testing
@testable import ConchTalk
import Foundation

@Suite("Truncated tool call handling")
struct TruncatedToolCallTests {

    @Test("截断的工具调用：不执行、不请求审批，回填截断说明后继续循环")
    func truncatedToolCallIsNotExecuted() async throws {
        let aiService = MockAIService()
        let toolRegistry = MockToolRegistry()
        let useCase = ExecuteNaturalLanguageCommandUseCase(
            aiService: aiService,
            sshClient: MockSSHClient(),
            toolRegistry: toolRegistry,
            serverID: nil,
            permissionLevel: .standard
        )
        let mockTool = MockTool(
            name: "write_file",
            safetyLevel: .needsConfirmation,
            executeResult: ToolExecutionResult(output: "written")
        )
        toolRegistry.register(mockTool)

        let confirmationRequested = LockedBox(false)
        useCase.onToolCallNeedsConfirmation = { _ in
            confirmationRequested.set(true)
            return .approvedOnce
        }

        var truncated = ToolCall(
            id: "toolu_cut",
            toolName: "write_file",
            argumentsJSON: Data(#"{"path":"/tmp/big","content":"aaa"#.utf8),
            explanation: "write_file"
        )
        truncated.truncatedByMaxTokens = true
        aiService.streamingResponses = [
            [.toolCall(truncated), .done],
            [.content("I'll split it into smaller writes."), .done],
        ]

        let messages = try await useCase.execute(
            userMessage: "Write a big file",
            conversationHistory: [],
            serverContext: ""
        )

        #expect(mockTool.executeCalled == 0)
        #expect(!confirmationRequested.value)
        #expect(messages.count == 2)
        #expect(messages[0].role == .command)
        #expect(messages[0].toolOutput == ExecuteNaturalLanguageCommandUseCase.truncatedToolCallOutput)
        #expect(messages[1].role == .assistant)
        // 截断说明作为工具结果回填给了模型
        let history = try #require(aiService.callHistory.last?.history)
        #expect(history.contains { $0.toolCall?.id == "toolu_cut" && $0.toolOutput == ExecuteNaturalLanguageCommandUseCase.truncatedToolCallOutput })
    }
}
