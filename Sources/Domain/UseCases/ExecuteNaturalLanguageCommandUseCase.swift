/// 文件说明：ExecuteNaturalLanguageCommandUseCase，负责编排自然语言指令在 AI 与工具之间的多轮执行闭环。
import Foundation

/// ExecuteNaturalLanguageCommandUseCase：
/// 将自然语言请求转为可执行步骤，按「AI 回复 -> 工具调用 -> 回填结果」循环推进，
/// 直到得到最终答案或达到安全迭代上限。
final class ExecuteNaturalLanguageCommandUseCase: @unchecked Sendable {
    private let aiService: AIServiceProtocol
    private let sshClient: SSHClientProtocol
    private let toolRegistry: ToolRegistryProtocol

    /// CommandApproval：表示高风险工具调用的用户审批结果。
    enum CommandApproval: Sendable {
        case approved
        case denied
    }

    /// 工具调用需要用户确认时触发（通常用于危险操作二次确认）。
    /// - Note: 未设置时默认按拒绝处理。
    var onToolCallNeedsConfirmation: (@Sendable (ToolCall) async -> CommandApproval)?
    /// 产生中间消息（如工具执行结果）时回调给 UI。
    /// - Side Effects: 调用方通常会据此立即更新消息列表。
    var onIntermediateMessage: (@MainActor @Sendable (Message) -> Void)?
    /// 流式推理文本增量回调。
    var onReasoningUpdate: (@MainActor @Sendable (String) -> Void)?
    /// 流式正文文本增量回调。
    var onContentUpdate: (@MainActor @Sendable (String) -> Void)?
    /// 工具执行过程中实时输出回调（累积文本）。
    /// - Note: 当工具支持流式执行时，每收到一块输出就会携带完整已累积文本回调，供 UI 实时展示。
    var onToolOutputUpdate: (@MainActor @Sendable (String) -> Void)?

    /// 初始化用例并注入执行链路依赖。
    /// - Parameters:
    ///   - aiService: AI 服务抽象，负责生成文本或工具调用。
    ///   - sshClient: SSH 客户端，供工具执行远端命令。
    ///   - toolRegistry: 工具注册表，用于按名称查找工具实现。
    init(aiService: AIServiceProtocol, sshClient: SSHClientProtocol, toolRegistry: ToolRegistryProtocol) {
        self.aiService = aiService
        self.sshClient = sshClient
        self.toolRegistry = toolRegistry
    }

    /// 执行自然语言指令主流程。
    /// - Parameters:
    ///   - userMessage: 用户最新输入。
    ///   - conversationHistory: 进入本轮前的历史消息。
    ///   - serverContext: 服务器上下文（主机、账号、系统等）。
    /// - Returns: 本轮新增消息（assistant/command/system），用于追加到会话。
    /// - Throws: 当 AI 流式请求失败、流中返回错误事件或上游服务异常时抛出。
    /// - Important: 内部最多执行 10 轮 agentic loop，避免无限工具循环。
    /// - Side Effects:
    ///   - 可能触发用户审批回调、流式文本回调和中间消息回调。
    ///   - 可能通过工具执行远端命令并产生外部系统副作用。
    /// - Error Handling:
    ///   - 工具不存在、参数解析失败、工具执行失败、审批拒绝、安全禁止等分支不会抛出，
    ///     而是生成系统/命令消息回填给模型后继续循环。
    func execute(userMessage: String, conversationHistory: [Message], serverContext: String) async throws -> [Message] {
        var newMessages: [Message] = []
        var history = conversationHistory

        // Send user message to AI via streaming
        var response = try await sendWithStreaming { [history] in
            self.aiService.sendMessageStreaming(userMessage, conversationHistory: history, serverContext: serverContext)
        }

        // Agentic loop
        let maxIterations = 50
        var iteration = 0
        while iteration < maxIterations {
            iteration += 1

            switch response {
            case .text(let text, let reasoning):
                let assistantMsg = Message(role: .assistant, content: text, reasoningContent: reasoning)
                newMessages.append(assistantMsg)
                onIntermediateMessage?(assistantMsg)
                return newMessages // Done!

            case .toolCall(let toolCall, let reasoning):
                // Each round's reasoning is attached to its own message
                let roundReasoning = reasoning
                // 错误分支：工具未注册，回填错误给模型并继续下一轮。
                guard let tool = toolRegistry.tool(named: toolCall.toolName) else {
                    let errorMsg = Message(role: .system, content: "Unknown tool: \(toolCall.toolName)")
                    newMessages.append(errorMsg)
                    history.append(errorMsg)
                    onIntermediateMessage?(errorMsg)

                    response = try await nextResponseAfterToolResult(
                        output: "ERROR: Unknown tool '\(toolCall.toolName)'",
                        toolCall: toolCall, history: history, serverContext: serverContext
                    )
                    continue
                }

                // 错误分支：工具参数无法解码，回填参数错误并继续下一轮。
                let arguments: [String: Any]
                do {
                    arguments = try toolCall.decodedArguments()
                } catch {
                    let errorMsg = Message(role: .system, content: "Failed to decode arguments for \(toolCall.toolName)")
                    newMessages.append(errorMsg)
                    history.append(errorMsg)

                    response = try await nextResponseAfterToolResult(
                        output: "ERROR: Invalid arguments",
                        toolCall: toolCall, history: history, serverContext: serverContext
                    )
                    continue
                }

                let safetyLevel = tool.validateSafety(arguments: arguments)

                switch safetyLevel {
                case .safe:
                    // 安全分支：直接执行工具。
                    onToolOutputUpdate?("")  // 重置实时输出
                    let result: ToolExecutionResult
                    do {
                        result = try await tool.execute(arguments: arguments, sshClient: sshClient)
                    } catch {
                        // 错误分支：工具执行失败，包装为 command 消息后回填模型继续推进。
                        print("[Tool] \(toolCall.toolName) execution error: \(error)")
                        let errorOutput = "ERROR: \(error.localizedDescription)"
                        onToolOutputUpdate?(errorOutput)
                        let errorMsg = Message(role: .command, content: toolCall.explanation, toolCall: toolCall, toolOutput: errorOutput, reasoningContent: roundReasoning)
                        newMessages.append(errorMsg)
                        history.append(errorMsg)
                        onIntermediateMessage?(errorMsg)

                        response = try await nextResponseAfterToolResult(
                            output: errorOutput, toolCall: toolCall, history: history, serverContext: serverContext
                        )
                        continue
                    }
                    // 工具执行完成后推送最终输出（当前为缓冲模式；未来接入 executeStreaming 后将逐块推送）。
                    onToolOutputUpdate?(result.output)
                    let cmdMsg = Message(role: .command, content: toolCall.explanation, toolCall: toolCall, toolOutput: result.output, reasoningContent: roundReasoning)
                    newMessages.append(cmdMsg)
                    history.append(cmdMsg)
                    onIntermediateMessage?(cmdMsg)

                    response = try await nextResponseAfterToolResult(
                        output: result.output, toolCall: toolCall, history: history, serverContext: serverContext
                    )

                case .needsConfirmation:
                    // 审批分支：等待调用方给出用户决策。
                    let approval = await onToolCallNeedsConfirmation?(toolCall) ?? .denied

                    if approval == .approved {
                        onToolOutputUpdate?("")  // 重置实时输出
                        let result: ToolExecutionResult
                        do {
                            result = try await tool.execute(arguments: arguments, sshClient: sshClient)
                        } catch {
                            // 错误分支：已审批但执行失败，同样回填错误并继续。
                            print("[Tool] \(toolCall.toolName) execution error: \(error)")
                            let errorOutput = "ERROR: \(error.localizedDescription)"
                            onToolOutputUpdate?(errorOutput)
                            let errorMsg = Message(role: .command, content: toolCall.explanation, toolCall: toolCall, toolOutput: errorOutput, reasoningContent: roundReasoning)
                            newMessages.append(errorMsg)
                            history.append(errorMsg)
                            onIntermediateMessage?(errorMsg)

                            response = try await nextResponseAfterToolResult(
                                output: errorOutput, toolCall: toolCall, history: history, serverContext: serverContext
                            )
                            continue
                        }
                        // 工具执行完成后推送最终输出。
                        onToolOutputUpdate?(result.output)
                        let cmdMsg = Message(role: .command, content: toolCall.explanation, toolCall: toolCall, toolOutput: result.output, reasoningContent: roundReasoning)
                        newMessages.append(cmdMsg)
                        history.append(cmdMsg)
                        onIntermediateMessage?(cmdMsg)

                        response = try await nextResponseAfterToolResult(
                            output: result.output, toolCall: toolCall, history: history, serverContext: serverContext
                        )
                    } else {
                        // 拒绝分支：不执行工具，明确告知模型该调用被拒绝。
                        let deniedMsg = Message(role: .system, content: "Tool call denied by user: \(toolCall.toolName)")
                        newMessages.append(deniedMsg)
                        history.append(deniedMsg)

                        response = try await nextResponseAfterToolResult(
                            output: "DENIED: User rejected this tool call",
                            toolCall: toolCall, history: history, serverContext: serverContext
                        )
                    }

                case .forbidden:
                    // 禁止分支：命中安全策略，直接阻断并回填阻断原因。
                    let blockedMsg = Message(role: .system, content: "Blocked dangerous tool call: \(toolCall.toolName)")
                    newMessages.append(blockedMsg)
                    history.append(blockedMsg)
                    onIntermediateMessage?(blockedMsg)

                    response = try await nextResponseAfterToolResult(
                        output: "BLOCKED: This operation is forbidden for safety reasons",
                        toolCall: toolCall, history: history, serverContext: serverContext
                    )
                }
            }
        }

        // 保护分支：达到最大迭代次数，优雅收敛而非硬停。
        switch response {
        case .text(let text, let reasoning):
            // 最后一轮 AI 已经给出了文本回复，直接返回即可。
            let assistantMsg = Message(role: .assistant, content: text, reasoningContent: reasoning)
            newMessages.append(assistantMsg)
            onIntermediateMessage?(assistantMsg)

        case .toolCall(let toolCall, _):
            // AI 仍想调用工具，用 tool result 通知它收敛并给出总结。
            let summaryResponse = try await sendWithStreaming { [history] in
                self.aiService.sendToolResultStreaming(
                    "SYSTEM: Tool execution limit reached. Do NOT call any more tools. Please provide a comprehensive final answer based on all the information you have gathered so far.",
                    forToolCall: toolCall,
                    conversationHistory: history,
                    serverContext: serverContext
                )
            }

            switch summaryResponse {
            case .text(let text, let reasoning):
                let assistantMsg = Message(role: .assistant, content: text, reasoningContent: reasoning)
                newMessages.append(assistantMsg)
                onIntermediateMessage?(assistantMsg)
            case .toolCall:
                // AI 仍然尝试调用工具，硬停兜底
                let timeoutMsg = Message(role: .system, content: "已达到工具调用上限，请查看上方已收集的信息。")
                newMessages.append(timeoutMsg)
            }
        }
        return newMessages
    }

    // MARK: - Streaming Helper

    /// 消费 `StreamingDelta` 流并聚合为单次 `AIResponse`。
    /// - Parameter streamFactory: 创建流式响应的工厂闭包。
    /// - Returns: 聚合后的文本响应或工具调用响应。
    /// - Throws: 当流中收到 `.error` 事件时抛出对应错误。
    /// - Side Effects: 逐段触发 `onReasoningUpdate` / `onContentUpdate` 回调。
    /// 待处理的剩余 tool call 队列（当模型一次返回多个 tool_calls 时使用）。
    private var pendingToolCalls: [ToolCall] = []

    /// 工具执行结果回填后决定下一步：若队列中还有待处理的 tool call 则直接返回，否则请求 AI。
    /// - Parameters:
    ///   - output: 刚执行完的工具输出文本。
    ///   - toolCall: 对应的工具调用信息。
    ///   - history: 当前完整会话历史。
    ///   - serverContext: 服务器上下文。
    /// - Returns: 下一个 tool call（队列非空时）或 AI 的新响应。
    private func nextResponseAfterToolResult(
        output: String,
        toolCall: ToolCall,
        history: [Message],
        serverContext: String
    ) async throws -> AIResponse {
        if !pendingToolCalls.isEmpty {
            return .toolCall(pendingToolCalls.removeFirst(), reasoning: nil)
        }
        return try await sendWithStreaming { [history] in
            self.aiService.sendToolResultStreaming(
                output, forToolCall: toolCall, conversationHistory: history, serverContext: serverContext
            )
        }
    }

    private func sendWithStreaming(_ streamFactory: @escaping @Sendable () -> AsyncStream<StreamingDelta>) async throws -> AIResponse {
        let stream = streamFactory()

        var accumulatedReasoning = ""
        var accumulatedContent = ""
        var resultToolCalls: [ToolCall] = []

        for await delta in stream {
            switch delta {
            case .reasoning(let chunk):
                accumulatedReasoning += chunk
                onReasoningUpdate?(chunk)
            case .content(let chunk):
                accumulatedContent += chunk
                onContentUpdate?(chunk)
            case .toolCall(let toolCall):
                resultToolCalls.append(toolCall)
            case .done:
                break
            case .error(let error):
                throw error
            }
        }

        let reasoning: String? = accumulatedReasoning.isEmpty ? nil : accumulatedReasoning

        if !resultToolCalls.isEmpty {
            // 首个 tool call 立即返回，其余存入待处理队列
            pendingToolCalls = Array(resultToolCalls.dropFirst())
            return .toolCall(resultToolCalls[0], reasoning: reasoning)
        }

        return .text(accumulatedContent, reasoning: reasoning)
    }
}
