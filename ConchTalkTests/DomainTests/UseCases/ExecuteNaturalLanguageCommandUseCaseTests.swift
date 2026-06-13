/// 文件说明：ExecuteNaturalLanguageCommandUseCaseTests，测试自然语言指令多轮执行闭环的核心用例。
import Testing
@testable import ConchTalk
import Foundation

@Suite("ExecuteNaturalLanguageCommandUseCase")
struct ExecuteNaturalLanguageCommandUseCaseTests {
    private struct TestStreamingError: Error {}

    private final class SlowStreamingAIService: AIServiceProtocol, @unchecked Sendable {
        private let delayBeforeDone: Duration

        init(delayBeforeDone: Duration) {
            self.delayBeforeDone = delayBeforeDone
        }

        func sendMessageStreaming(
            _ message: String,
            conversationHistory: [Message],
            serverContext: String,
            serverID: UUID?,
            permissionLevel: PermissionLevel,
            serverName: String,
            serverCapabilities: ServerCapabilities
        ) -> AsyncStream<StreamingDelta> {
            AsyncStream { continuation in
                Task {
                    continuation.yield(.content("partial response"))
                    try? await Task.sleep(for: self.delayBeforeDone)
                    continuation.yield(.done)
                    continuation.finish()
                }
            }
        }

        func sendToolResultStreaming(
            _ result: String,
            forToolCall: ToolCall,
            conversationHistory: [Message],
            serverContext: String,
            serverID: UUID?,
            permissionLevel: PermissionLevel,
            serverName: String,
            serverCapabilities: ServerCapabilities
        ) -> AsyncStream<StreamingDelta> {
            AsyncStream { continuation in
                continuation.yield(.done)
                continuation.finish()
            }
        }

        func generateMemorySummary(
            recentMessages: [Message],
            existingConversationMemory: String?,
            existingServerMemory: String?,
            existingGlobalMemory: String?
        ) async throws -> MemorySummaryResult {
            MemorySummaryResult(conversationMemory: nil, serverMemory: nil, globalMemory: nil)
        }
        func sendSimpleMessage(_ prompt: String) async throws -> String { "" }
    }

    private actor Counter {
        private(set) var value = 0
        func increment() { value += 1 }
    }

    private actor CountingSubagentRunner: SubagentRunning {
        private(set) var callCount = 0

        func run(tasks: [SubagentTask]) async -> [SubagentResult] {
            callCount += 1
            return tasks.map {
                SubagentResult(
                    subagentName: $0.subagentType,
                    task: $0.prompt,
                    outcome: "ok",
                    succeeded: true,
                    errorSummary: nil
                )
            }
        }
    }

    // MARK: - 辅助方法

    /// 构造被测用例及其依赖的 Mock 对象。
    private func makeUseCase(
        aiService: MockAIService = MockAIService(),
        toolRegistry: MockToolRegistry = MockToolRegistry(),
        sshClient: MockSSHClient = MockSSHClient(),
        permissionLevel: PermissionLevel = .standard
    ) -> (ExecuteNaturalLanguageCommandUseCase, MockAIService, MockToolRegistry, MockSSHClient) {
        let useCase = ExecuteNaturalLanguageCommandUseCase(
            aiService: aiService,
            sshClient: sshClient,
            toolRegistry: toolRegistry,
            serverID: nil,
            permissionLevel: permissionLevel
        )
        return (useCase, aiService, toolRegistry, sshClient)
    }

    // MARK: - 1. 纯文本回复

    @Test("AI returns text only produces single assistant message")
    func textResponseOnly() async throws {
        let (useCase, aiService, _, _) = makeUseCase()
        aiService.streamingResponses = [
            [.content("Hello!"), .done]
        ]

        let messages = try await useCase.execute(
            userMessage: "Hi",
            conversationHistory: [],
            serverContext: ""
        )

        #expect(messages.count == 1)
        #expect(messages[0].role == .assistant)
        #expect(messages[0].content == "Hello!")
    }

    // MARK: - 2. 带推理链的文本回复

    @Test("AI returns reasoning then content produces message with reasoningContent")
    func textWithReasoning() async throws {
        let (useCase, aiService, _, _) = makeUseCase()
        aiService.streamingResponses = [
            [.reasoning("think"), .content("answer"), .done]
        ]

        let messages = try await useCase.execute(
            userMessage: "Why?",
            conversationHistory: [],
            serverContext: ""
        )

        #expect(messages.count == 1)
        #expect(messages[0].role == .assistant)
        #expect(messages[0].content == "answer")
        #expect(messages[0].reasoningContent == "think")
    }

    @Test("Empty visible reply produces fallback assistant text instead of blank bubble")
    func emptyVisibleReplyUsesFallbackText() async throws {
        let (useCase, aiService, _, _) = makeUseCase()
        aiService.streamingResponses = [
            [.done]
        ]

        let messages = try await useCase.execute(
            userMessage: "Check system status",
            conversationHistory: [],
            serverContext: ""
        )

        #expect(messages.count == 1)
        #expect(messages[0].role == .assistant)
        #expect(messages[0].content.isEmpty == false)
        #expect(messages[0].content.contains("no visible reply"))
    }

    // MARK: - 3. 安全工具自动执行

    @Test("Safe tool executes automatically without confirmation")
    func safeToolExecution() async throws {
        let (useCase, aiService, toolRegistry, _) = makeUseCase()
        let mockTool = MockTool(
            name: "read_file",
            safetyLevel: .safe,
            executeResult: ToolExecutionResult(output: "file content here")
        )
        toolRegistry.register(mockTool)

        let toolCall = TestFixtures.makeToolCall(
            id: "call_1",
            toolName: "read_file",
            arguments: ["path": "/etc/hostname"]
        )
        aiService.streamingResponses = [
            [.toolCall(toolCall), .done],
            [.content("The file contains your hostname."), .done]
        ]

        let messages = try await useCase.execute(
            userMessage: "Read the hostname file",
            conversationHistory: [],
            serverContext: ""
        )

        #expect(mockTool.executeCalled == 1)
        #expect(messages.count == 2)
        #expect(messages[0].role == .command)
        #expect(messages[0].toolOutput == "file content here")
        #expect(messages[1].role == .assistant)
        #expect(messages[1].content == "The file contains your hostname.")
    }

    @Test("Tool arguments inject serverID but not legacy conversationID")
    func toolArgumentsUseServerIDOnly() async throws {
        let aiService = MockAIService()
        let toolRegistry = MockToolRegistry()
        let sshClient = MockSSHClient()
        let serverID = UUID()
        let useCase = ExecuteNaturalLanguageCommandUseCase(
            aiService: aiService,
            sshClient: sshClient,
            toolRegistry: toolRegistry,
            serverID: serverID,
            permissionLevel: .standard
        )

        let mockTool = MockTool(
            name: "read_file",
            safetyLevel: .safe,
            executeResult: ToolExecutionResult(output: "ok")
        )
        toolRegistry.register(mockTool)

        let toolCall = TestFixtures.makeToolCall(
            id: "call_server_id",
            toolName: "read_file",
            arguments: ["path": "/tmp/demo.txt"]
        )
        aiService.streamingResponses = [
            [.toolCall(toolCall), .done],
            [.content("done"), .done]
        ]

        _ = try await useCase.execute(
            userMessage: "Read file",
            conversationHistory: [],
            serverContext: ""
        )

        let args = try #require(mockTool.lastArguments)
        #expect(args["_serverID"] as? String == serverID.uuidString)
        #expect(args["_conversationID"] == nil)
    }

    // MARK: - 4. 需确认工具 — 用户批准

    @Test("NeedsConfirmation tool executes when user approves")
    func needsConfirmationApproved() async throws {
        let (useCase, aiService, toolRegistry, _) = makeUseCase()
        let mockTool = MockTool(
            name: "execute_ssh_command",
            safetyLevel: .needsConfirmation,
            executeResult: ToolExecutionResult(output: "done")
        )
        toolRegistry.register(mockTool)

        useCase.onToolCallNeedsConfirmation = { _ in .approved }

        let toolCall = TestFixtures.makeToolCall(
            id: "call_2",
            toolName: "execute_ssh_command",
            arguments: ["command": "apt update"]
        )
        aiService.streamingResponses = [
            [.toolCall(toolCall), .done],
            [.content("Update complete."), .done]
        ]

        let messages = try await useCase.execute(
            userMessage: "Update packages",
            conversationHistory: [],
            serverContext: ""
        )

        #expect(mockTool.executeCalled == 1)
        #expect(messages.count == 2)
        #expect(messages[0].role == .command)
        #expect(messages[1].role == .assistant)
    }

    // MARK: - 5. 需确认工具 — 用户拒绝

    @Test("NeedsConfirmation tool not executed when user denies")
    func needsConfirmationDenied() async throws {
        let (useCase, aiService, toolRegistry, _) = makeUseCase()
        let mockTool = MockTool(
            name: "execute_ssh_command",
            safetyLevel: .needsConfirmation,
            executeResult: ToolExecutionResult(output: "should not run")
        )
        toolRegistry.register(mockTool)

        useCase.onToolCallNeedsConfirmation = { _ in .denied }

        let toolCall = TestFixtures.makeToolCall(
            id: "call_3",
            toolName: "execute_ssh_command",
            arguments: ["command": "rm -rf /tmp/test"]
        )
        // 第一轮：AI 返回 toolCall → 被拒绝
        // 拒绝后直接回填拒绝结果，AI 自然语言回复
        aiService.streamingResponses = [
            [.toolCall(toolCall), .done],
            [.content("OK I won't do that."), .done]
        ]

        let messages = try await useCase.execute(
            userMessage: "Delete temp files",
            conversationHistory: [],
            serverContext: ""
        )

        #expect(mockTool.executeCalled == 0)
        // 应包含 commandDenied 系统消息
        let deniedMessages = messages.filter { $0.systemMessageType == .commandDenied }
        #expect(deniedMessages.count == 1)
    }

    // MARK: - 6. 禁止执行的工具

    @Test("Forbidden tool is blocked and not executed")
    func forbiddenToolBlocked() async throws {
        let (useCase, aiService, toolRegistry, _) = makeUseCase()
        let mockTool = MockTool(
            name: "execute_ssh_command",
            safetyLevel: .forbidden,
            executeResult: ToolExecutionResult(output: "should not run")
        )
        toolRegistry.register(mockTool)

        let toolCall = TestFixtures.makeToolCall(
            id: "call_4",
            toolName: "execute_ssh_command",
            arguments: ["command": "rm -rf /"]
        )
        aiService.streamingResponses = [
            [.toolCall(toolCall), .done],
            [.content("I cannot execute that dangerous command."), .done]
        ]

        let messages = try await useCase.execute(
            userMessage: "Wipe everything",
            conversationHistory: [],
            serverContext: ""
        )

        #expect(mockTool.executeCalled == 0)
        // 最后一条应是 assistant 消息（AI 解释为何不能执行）
        let lastMessage = messages.last
        #expect(lastMessage?.role == .assistant)
    }

    // MARK: - 7. 未知工具

    @Test("Unknown tool produces error message and loop continues to text response")
    func unknownTool() async throws {
        let (useCase, aiService, _, _) = makeUseCase()
        // 不注册任何工具

        let toolCall = TestFixtures.makeToolCall(
            id: "call_5",
            toolName: "nonexistent_tool",
            arguments: ["foo": "bar"]
        )
        aiService.streamingResponses = [
            [.toolCall(toolCall), .done],
            [.content("Sorry, that tool doesn't exist."), .done]
        ]

        let messages = try await useCase.execute(
            userMessage: "Do something",
            conversationHistory: [],
            serverContext: ""
        )

        // 应包含关于未知工具的系统错误消息
        let systemMessages = messages.filter { $0.role == .system }
        #expect(systemMessages.count >= 1)
        let unknownMsg = systemMessages.first { $0.content.contains("Unknown tool") }
        #expect(unknownMsg != nil)
        // 循环继续后应有 assistant 回复
        let assistantMessages = messages.filter { $0.role == .assistant }
        #expect(assistantMessages.count == 1)
    }

    // MARK: - 8. 严格模式提升安全工具为需确认

    @Test("Strict mode elevates safe tool to needsConfirmation")
    func strictModeElevatesSafe() async throws {
        let (useCase, aiService, toolRegistry, _) = makeUseCase(permissionLevel: .strict)
        let mockTool = MockTool(
            name: "read_file",
            safetyLevel: .safe,
            executeResult: ToolExecutionResult(output: "file content")
        )
        toolRegistry.register(mockTool)

        let confirmationCalled = LockedBox(false)
        useCase.onToolCallNeedsConfirmation = { _ in
            confirmationCalled.set(true)
            return .approved
        }

        let toolCall = TestFixtures.makeToolCall(
            id: "call_6",
            toolName: "read_file",
            arguments: ["path": "/etc/hosts"]
        )
        aiService.streamingResponses = [
            [.toolCall(toolCall), .done],
            [.content("Here are your hosts."), .done]
        ]

        _ = try await useCase.execute(
            userMessage: "Show hosts file",
            conversationHistory: [],
            serverContext: ""
        )

        #expect(confirmationCalled.value == true)
        #expect(mockTool.executeCalled == 1)
    }

    @Test("Strict mode confirms dispatch_subagent before running subagents")
    func strictModeConfirmsDispatchSubagent() async throws {
        let (useCase, aiService, _, _) = makeUseCase(permissionLevel: .strict)
        let runner = CountingSubagentRunner()
        useCase.subagentRunner = runner

        let dispatchCall = TestFixtures.makeToolCall(
            id: "dispatch_1",
            toolName: DispatchSubagentTool.toolName,
            arguments: ["tasks": [["subagent_type": "explorer", "prompt": "find auth"]]]
        )
        aiService.streamingResponses = [
            [.toolCall(dispatchCall), .done],
            [.content("Dispatch denied."), .done],
        ]

        let confirmationCount = Counter()
        useCase.onToolCallNeedsConfirmation = { _ in
            await confirmationCount.increment()
            return .denied
        }

        let messages = try await useCase.execute(
            userMessage: "dispatch",
            conversationHistory: [],
            serverContext: ""
        )

        #expect(await confirmationCount.value == 1)
        #expect(await runner.callCount == 0)
        #expect(messages.contains { $0.systemMessageType == .commandDenied })
        #expect(messages.last?.role == .assistant)
        #expect(messages.last?.content == "Dispatch denied.")
    }

    // MARK: - 9. 宽松模式降级需确认工具为安全

    @Test("Permissive mode downgrades needsConfirmation to safe, auto-executes")
    func permissiveModeDowngrades() async throws {
        let (useCase, aiService, toolRegistry, _) = makeUseCase(permissionLevel: .permissive)
        let mockTool = MockTool(
            name: "execute_ssh_command",
            safetyLevel: .needsConfirmation,
            executeResult: ToolExecutionResult(output: "executed")
        )
        toolRegistry.register(mockTool)

        let confirmationCalled = LockedBox(false)
        useCase.onToolCallNeedsConfirmation = { _ in
            confirmationCalled.set(true)
            return .approved
        }

        let toolCall = TestFixtures.makeToolCall(
            id: "call_7",
            toolName: "execute_ssh_command",
            arguments: ["command": "ls"]
        )
        aiService.streamingResponses = [
            [.toolCall(toolCall), .done],
            [.content("Directory listed."), .done]
        ]

        _ = try await useCase.execute(
            userMessage: "List files",
            conversationHistory: [],
            serverContext: ""
        )

        // 宽松模式下 needsConfirmation 被降为 safe，不应调用确认回调
        #expect(confirmationCalled.value == false)
        #expect(mockTool.executeCalled == 1)
    }

    // MARK: - 10. 工具执行异常

    @Test("Tool execution error feeds error back to AI and loop continues")
    func toolExecutionError() async throws {
        let (useCase, aiService, toolRegistry, _) = makeUseCase()
        let mockTool = MockTool(
            name: "read_file",
            safetyLevel: .safe,
            executeResult: ToolExecutionResult(output: "unused")
        )
        mockTool.executeError = NSError(domain: "TestError", code: 42, userInfo: [NSLocalizedDescriptionKey: "Permission denied"])
        toolRegistry.register(mockTool)

        let toolCall = TestFixtures.makeToolCall(
            id: "call_8",
            toolName: "read_file",
            arguments: ["path": "/root/secret"]
        )
        aiService.streamingResponses = [
            [.toolCall(toolCall), .done],
            [.content("I couldn't read that file due to permissions."), .done]
        ]

        let messages = try await useCase.execute(
            userMessage: "Read secret file",
            conversationHistory: [],
            serverContext: ""
        )

        #expect(mockTool.executeCalled == 1)
        // 错误被回填为 command 消息
        let commandMessages = messages.filter { $0.role == .command }
        #expect(commandMessages.count == 1)
        #expect(commandMessages[0].toolOutput?.contains("ERROR") == true)
        // 循环继续产生 assistant 回复
        let assistantMessages = messages.filter { $0.role == .assistant }
        #expect(assistantMessages.count == 1)
    }

    @Test("Cancellation propagates when execute task is cancelled")
    func executeCancellationPropagates() async {
        let aiService = SlowStreamingAIService(delayBeforeDone: .seconds(2))
        let useCase = ExecuteNaturalLanguageCommandUseCase(
            aiService: aiService,
            sshClient: MockSSHClient(),
            toolRegistry: MockToolRegistry(),
            serverID: nil,
            permissionLevel: .standard
        )

        let task = Task {
            try await useCase.execute(
                userMessage: "long running request",
                conversationHistory: [],
                serverContext: ""
            )
        }

        try? await Task.sleep(for: .milliseconds(100))
        task.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
    }

    @Test("Streaming error from sendMessageStreaming is propagated")
    func initialStreamingErrorIsPropagated() async {
        let (useCase, aiService, _, _) = makeUseCase()
        aiService.streamingResponses = [[.error(TestStreamingError())]]

        await #expect(throws: TestStreamingError.self) {
            _ = try await useCase.execute(
                userMessage: "trigger error",
                conversationHistory: [],
                serverContext: ""
            )
        }
    }

    @Test("Streaming error after tool result is propagated")
    func toolResultStreamingErrorIsPropagated() async {
        let (useCase, aiService, toolRegistry, _) = makeUseCase()
        let mockTool = MockTool(
            name: "read_file",
            safetyLevel: .safe,
            executeResult: ToolExecutionResult(output: "ok")
        )
        toolRegistry.register(mockTool)

        let toolCall = TestFixtures.makeToolCall(
            id: "call_error_after_tool",
            toolName: "read_file",
            arguments: ["path": "/tmp/a.txt"]
        )
        aiService.streamingResponses = [
            [.toolCall(toolCall), .done],
            [.error(TestStreamingError())]
        ]

        await #expect(throws: TestStreamingError.self) {
            _ = try await useCase.execute(
                userMessage: "read file",
                conversationHistory: [],
                serverContext: ""
            )
        }
    }

    // MARK: - 11. 可注入 maxIterations

    @Test("注入的 maxIterations 生效：循环按注入上限停止并触发收敛总结")
    func customMaxIterations() async throws {
        let aiService = MockAIService()
        let toolRegistry = MockToolRegistry()
        let sshClient = MockSSHClient()
        let useCase = ExecuteNaturalLanguageCommandUseCase(
            aiService: aiService,
            sshClient: sshClient,
            toolRegistry: toolRegistry,
            serverID: nil,
            permissionLevel: .standard,
            maxIterations: 1
        )
        let tool = MockTool(
            name: "read_file",
            safetyLevel: .safe,
            executeResult: ToolExecutionResult(output: "x")
        )
        toolRegistry.register(tool)

        let call = TestFixtures.makeToolCall(id: "c", toolName: "read_file", arguments: ["path": "/a"])
        // AI 始终想调用工具，用于检验循环是否真的按注入上限停止：
        // [0] 初始 sendMessageStreaming → toolCall（消耗唯一一轮循环体）
        // [1] 工具回填后 sendToolResultStreaming → 仍 toolCall（此时已达上限，进入收敛分支）
        // [2] 收敛总结请求 → 返回最终文本
        // 若注入未生效（沿用默认 50），[1] 的 toolCall 会驱动工具被第二次执行。
        aiService.streamingResponses = [
            [.toolCall(call), .done],
            [.toolCall(call), .done],
            [.content("final summary"), .done]
        ]

        let messages = try await useCase.execute(
            userMessage: "go",
            conversationHistory: [],
            serverContext: ""
        )

        // 关键断言：循环只跑了 1 轮 → 工具仅执行 1 次（默认 50 时会执行 2 次），证明注入的上限被使用。
        #expect(tool.executeCalled == 1)
        // 达到上限后触发收敛总结：最终消息为 assistant，内容来自收敛响应 [2]。
        #expect(messages.last?.role == .assistant)
        #expect(messages.last?.content == "final summary")
        // 调用次数：初始 1 次 sendMessageStreaming；工具回填 + 收敛提示共 2 次 sendToolResultStreaming。
        #expect(aiService.callCount("sendMessageStreaming") == 1)
        #expect(aiService.callCount("sendToolResultStreaming") == 2)
    }

    // MARK: - 循环内压缩（问题 6a）

    /// 构造带压缩依赖的用例：MockTool 每轮回大输出，注入小 maxContextTokens。
    /// 注意：ToolExecutionResult.init 自带 8000 字符硬截断，单轮输出须 ≤ 8000 字符才能精确控制
    /// token 数学，靠轮数累积把历史推过压缩阈值。
    private func makeCompactingUseCase(
        toolOutputChars: Int,
        maxContextTokens: Int,
        rounds: Int = 5
    ) -> (ExecuteNaturalLanguageCommandUseCase, MockAIService) {
        let aiService = MockAIService()
        aiService.simpleMessageResult = "MID-TASK SUMMARY"  // ContextCompactor 的摘要返回

        // rounds 轮 toolCall + 最后一轮文本回复（分步赋值帮助字面量类型推断）
        let toolCall = TestFixtures.makeToolCall(toolName: "mock_tool", arguments: [:])
        var responses: [[StreamingDelta]] = (0..<rounds).map { _ in [.toolCall(toolCall), .done] }
        responses.append([.content("done"), .done])
        aiService.streamingResponses = responses

        let registry = MockToolRegistry()
        let tool = MockTool()
        tool.name = "mock_tool"
        tool.executeResult = ToolExecutionResult(
            output: String(repeating: "y", count: toolOutputChars))
        registry.register(tool)

        let useCase = ExecuteNaturalLanguageCommandUseCase(
            aiService: aiService,
            sshClient: MockSSHClient(),
            toolRegistry: registry,
            serverID: UUID(),  // 压缩链路需要 serverID
            permissionLevel: .standard
        )
        let memoryService = MockMemoryService()
        let entryStore = MockMemoryEntryStore()
        useCase.contextBuilder = ContextBuilder(memoryContextProvider: memoryService)
        useCase.contextCompactor = ContextCompactor(
            aiService: aiService,
            retainService: RetainService(
                aiService: aiService, memoryWriter: memoryService, entryStore: entryStore),
            reflectService: ReflectService(
                aiService: aiService, entryStore: entryStore,
                memoryWriter: memoryService, memoryReader: memoryService)
        )
        useCase.maxContextTokens = maxContextTokens
        return (useCase, aiService)
    }

    @Test("循环中段历史超限时触发压缩")
    func loopCompactsWhenHistoryGrowsMidTask() async throws {
        // 每轮工具输出 7_900 ASCII 字符 ≈ 1_975 token（低于实体 8K 截断，数学精确）；
        // 窗口 45_000，reserve 20_000 → 估算超过 25_000（约第 13 轮）后剩余预算 < 20k，
        // 且历史超过 recentTokenBudget(20k)，压缩在循环中段真实触发并裁剪头部
        let (useCase, aiService) = makeCompactingUseCase(
            toolOutputChars: 7_900, maxContextTokens: 45_000, rounds: 15)

        var compressingEvents: [Bool] = []
        useCase.onContextCompressing = { compressingEvents.append($0) }

        let messages = try await useCase.execute(
            userMessage: "do heavy work",
            conversationHistory: [],
            serverContext: "ctx"
        )

        // 压缩被触发：true/false 回调 + ContextCompactor 的摘要调用
        #expect(compressingEvents.contains(true))
        #expect(compressingEvents.contains(false))
        #expect(aiService.didCall("sendSimpleMessage"))
        // 压缩后某次工具结果请求的 history 首条为 .aiContext 摘要
        let toolResultCalls = aiService.callHistory.filter { $0.method == "sendToolResultStreaming" }
        let compactedCall = toolResultCalls.first { call in
            call.history?.first?.systemMessageType == .aiContext
        }
        #expect(compactedCall != nil)
        // 任务仍正常收敛到文本回复
        #expect(messages.last?.role == .assistant)
        #expect(messages.last?.content == "done")
    }

    @Test("低于阈值时循环内不触发压缩")
    func loopNoCompactionBelowThreshold() async throws {
        // 小输出（100 字符/轮）+ 默认大窗口：永不触发
        let (useCase, aiService) = makeCompactingUseCase(
            toolOutputChars: 100, maxContextTokens: 100_000)

        var compressingEvents: [Bool] = []
        useCase.onContextCompressing = { compressingEvents.append($0) }

        let messages = try await useCase.execute(
            userMessage: "light work",
            conversationHistory: [],
            serverContext: "ctx"
        )

        #expect(compressingEvents.isEmpty)
        #expect(!aiService.didCall("sendSimpleMessage"))
        #expect(messages.last?.content == "done")
    }
}
