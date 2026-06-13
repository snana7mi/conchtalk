/// 文件说明：ExecuteNaturalLanguageCommandUseCase，负责编排自然语言指令在 AI 与工具之间的多轮执行闭环。
import Foundation

/// ExecuteNaturalLanguageCommandUseCase：
/// 将自然语言请求转为可执行步骤，按「AI 回复 -> 工具调用 -> 回填结果」循环推进，
/// 直到得到最终答案或达到安全迭代上限。
nonisolated final class ExecuteNaturalLanguageCommandUseCase: @unchecked Sendable {
    /// LocalizedTexts：
    /// 用例内系统提示文案的可注入本地化文本集合，避免 Domain 层依赖具体语言设置实现。
    struct LocalizedTexts: Sendable {
        let userRejectedCommand: String

        static let english = LocalizedTexts(
            userRejectedCommand: "User rejected this command"
        )
    }

    private let aiService: AIServiceProtocol
    private let sshClient: SSHClientProtocol
    private let toolRegistry: ToolRegistryProtocol

    /// 当前服务器 ID，注入到工具参数中供终端工具等使用。
    let serverID: UUID?
    /// 当前生效的操作权限等级。
    let permissionLevel: PermissionLevel
    /// 注入的本地化文案。
    private let localizedTexts: LocalizedTexts
    /// agentic loop 最大迭代轮数（默认 50；子 agent 注入更小值以更快收敛）。
    private let maxIterations: Int

    /// 上下文组装器（可选）：组装 system prompt + 记忆 + 历史消息，估算 token 并标记是否需要压缩。
    var contextBuilder: ContextBuilder?
    /// 上下文压缩器（可选）：Memory Flush + 摘要生成，在 token 接近上限时裁剪历史。
    var contextCompactor: ContextCompactor?
    /// 上下文最大 token 数，与 contextBuilder/contextCompactor 配合使用。
    var maxContextTokens: Int = 100_000

    /// 工具调用需要用户确认时触发（通常用于危险操作二次确认）。
    /// - Note: 未设置时默认按拒绝处理。
    var onToolCallNeedsConfirmation: (@Sendable (ToolCall) async -> CommandApproval)?
    /// AI 通过 `suggest_agent_connection` 工具建议连接编码代理时触发。
    /// - Parameter preferredAgent: AI 建议的代理类型（可为 nil）。
    /// - Returns: 用户的选择结果。
    var onAgentConnectionSuggested: (@Sendable (_ preferredAgent: String?, _ cwd: String?, _ directories: [String]?, _ homePath: String?) async -> AgentConnectionResult)?
    /// subagent 编排器（注入后启用 `dispatch_subagent` 拦截分支）。
    /// - Note: 未注入时该工具会被回填一句 ERROR，让模型自行收敛而非崩溃。
    var subagentRunner: SubagentRunning?
    /// 产生中间消息（如工具执行结果）时回调给 UI。
    /// - Side Effects: 调用方通常会据此立即更新消息列表。
    var onIntermediateMessage: (@MainActor @Sendable (Message) -> Void)?
    /// 流式推理文本回调（传递当前累积全文，而非增量）。
    var onReasoningUpdate: (@MainActor @Sendable (String) -> Void)?
    /// 流式正文文本回调（传递当前累积全文，而非增量）。
    var onContentUpdate: (@MainActor @Sendable (String) -> Void)?
    /// 工具执行过程中实时输出回调（累积文本）。
    /// - Note: 当工具支持流式执行时，每收到一块输出就会携带完整已累积文本回调，供 UI 实时展示。
    var onToolOutputUpdate: (@MainActor @Sendable (String) -> Void)?
    /// ACP 编码代理流式事件批量回调（已在后台完成 JSON 解码）。
    /// 与 150ms 文本节流窗口对齐，每个窗口内解析出的事件一次性推送。
    var onAgentStreamEvents: (@MainActor @Sendable ([AgentStreamEvent]) -> Void)?
    /// 上下文压缩状态变化回调。`true` = 压缩开始，`false` = 压缩结束（AI 回复已开始）。
    var onContextCompressing: (@MainActor @Sendable (Bool) -> Void)?

    /// 服务器名称，用于 AI 身份标识。
    var serverName: String = "AI Assistant"

    /// 用户附带的文件附件，在工具执行时注入到参数中。
    var attachments: [FileAttachment] = []

    /// 本次执行过程中是否有 `.needsConfirmation` 级别的工具调用被批准并执行。
    /// 由 TaskExecutionCoordinator 读取，用于判断是否需要刷新系统环境探测结果。
    /// 安全性：写入发生在 execute() 内部，读取发生在 execute() 返回后，天然顺序访问。
    var hadWriteOperations = false


    /// 初始化用例并注入执行链路依赖。
    /// - Parameters:
    ///   - aiService: AI 服务抽象，负责生成文本或工具调用。
    ///   - sshClient: SSH 客户端，供工具执行远端命令。
    ///   - toolRegistry: 工具注册表，用于按名称查找工具实现。
    init(
        aiService: AIServiceProtocol,
        sshClient: SSHClientProtocol,
        toolRegistry: ToolRegistryProtocol,
        serverID: UUID? = nil,
        permissionLevel: PermissionLevel = .standard,
        localizedTexts: LocalizedTexts = .english,
        maxIterations: Int = 50
    ) {
        self.aiService = aiService
        self.sshClient = sshClient
        self.toolRegistry = toolRegistry
        self.serverID = serverID
        self.permissionLevel = permissionLevel
        self.localizedTexts = localizedTexts
        self.maxIterations = maxIterations
    }

    /// 执行自然语言指令主流程。
    /// - Parameters:
    ///   - userMessage: 用户最新输入。
    ///   - conversationHistory: 进入本轮前的历史消息。
    ///   - serverContext: 服务器上下文（主机、账号、系统等）。
    /// - Returns: 本轮新增消息（assistant/command/system），用于追加到会话。
    /// - Throws: 当 AI 流式请求失败、流中返回错误事件或上游服务异常时抛出。
    /// - Important: 内部最多执行 `maxIterations` 轮 agentic loop（默认 50，子 agent 可注入更小值），避免无限工具循环。
    /// - Side Effects:
    ///   - 可能触发用户审批回调、流式文本回调和中间消息回调。
    ///   - 可能通过工具执行远端命令并产生外部系统副作用。
    /// - Error Handling:
    ///   - 工具不存在、参数解析失败、工具执行失败、审批拒绝、安全禁止等分支不会抛出，
    ///     而是生成系统/命令消息回填给模型后继续循环。
    /// 过滤掉最后一个 contextBreak 之前的所有消息，仅保留断点之后的内容。
    /// 若不存在 contextBreak，则返回全部消息。
    static func filterAfterLastContextBreak(_ messages: [Message]) -> [Message] {
        guard let lastBreakIndex = messages.lastIndex(where: { $0.systemMessageType == .contextBreak }) else {
            return messages
        }
        return Array(messages.suffix(from: messages.index(after: lastBreakIndex)))
    }

    func execute(userMessage: String, conversationHistory: [Message], serverContext: String) async throws -> [Message] {
        var newMessages: [Message] = []

        // 获取服务器能力，用于过滤 AI 可见的工具列表
        let capabilities = await sshClient.serverCapabilities

        // 上下文断点过滤：仅保留最后一个 contextBreak 之后的消息
        let filteredHistory = Self.filterAfterLastContextBreak(conversationHistory)

        // 可选的上下文构建与压缩：组装 token 估算，必要时触发 Memory Flush + 摘要压缩
        var history = filteredHistory
        if let builder = contextBuilder, let serverID {
            let builtContext = await builder.buildContext(
                serverID: serverID,
                userInput: userMessage,
                systemPrompt: serverContext,
                messages: filteredHistory,
                maxContextTokens: maxContextTokens
            )
            if builtContext.needsCompaction, let compactor = contextCompactor {
                // 通知 UI 压缩开始
                await onContextCompressing?(true)
                if let compactionResult = await compactor.compactIfNeeded(
                    serverID: serverID,
                    messages: builtContext.messages,
                    maxContextTokens: maxContextTokens,
                    currentTokens: builtContext.estimatedTokens
                ) {
                    history = compactionResult.compactedMessages
                }
                // 通知 UI 压缩结束
                await onContextCompressing?(false)
            }
        }

        // Send user message to AI via streaming
        var response = try await sendWithStreaming { [history, capabilities] in
            self.aiService.sendMessageStreaming(userMessage, conversationHistory: history, serverContext: serverContext, serverID: self.serverID, permissionLevel: self.permissionLevel, serverName: self.serverName, serverCapabilities: capabilities)
        }

        // Agentic loop
        var iteration = 0
        while iteration < maxIterations {
            try Task.checkCancellation()
            iteration += 1

            switch response {
            case .text(let text, let reasoning):
                let assistantMsg = Message(role: .assistant, content: text, reasoningContent: reasoning)
                newMessages.append(assistantMsg)
                await onIntermediateMessage?(assistantMsg)
                return newMessages // Done!

            case .toolCall(let toolCall, let reasoning):
                // Each round's reasoning is attached to its own message
                let roundReasoning = reasoning

                // MARK: suggest_agent_connection 拦截
                if toolCall.toolName == "suggest_agent_connection" {
                    let interceptResult = await SpecialToolHandler.handleSuggestAgentConnection(
                        toolCall: toolCall,
                        reasoning: roundReasoning,
                        callback: { [onAgentConnectionSuggested] agent, cwd, dirs, home in
                            await onAgentConnectionSuggested?(agent, cwd, dirs, home) ?? .cancelled
                        }
                    )
                    for msg in interceptResult.constructedMessages {
                        newMessages.append(msg)
                        history.append(msg)
                        await onIntermediateMessage?(msg)
                    }
                    switch interceptResult.interceptResult {
                    case .continueLoop(let output):
                        response = try await nextResponseAfterToolResult(
                            output: output, toolCall: toolCall, history: &history, serverContext: serverContext, serverCapabilities: capabilities
                        )
                        continue
                    case .exitLoop:
                        return newMessages
                    }
                }

                // MARK: dispatch_subagent 拦截
                // 与 suggest_agent_connection 同属特殊工具拦截：派生子 agent 执行，落结论卡 + 回填汇总文本。
                if toolCall.toolName == DispatchSubagentTool.toolName {
                    // strict 模式下 safe 工具也需确认；特殊工具拦截发生在通用 ToolSafetyGate 前，
                    // 因此这里显式应用同一权限映射，避免绕过全局确认策略。
                    if permissionLevel.effectiveSafetyLevel(.safe) == .needsConfirmation {
                        let approval = await onToolCallNeedsConfirmation?(toolCall) ?? .denied
                        guard approval == .approved else {
                            let deniedOutput = "DENIED: User rejected this subagent dispatch. Acknowledge the denial briefly and ask how to proceed."
                            let deniedMsg = Message(
                                role: .system,
                                content: localizedTexts.userRejectedCommand,
                                toolCall: toolCall,
                                reasoningContent: roundReasoning,
                                systemMessageType: .commandDenied
                            )
                            newMessages.append(deniedMsg)
                            history.append(deniedMsg)
                            await onIntermediateMessage?(deniedMsg)

                            let toolResult = Message(
                                role: .command,
                                content: toolCall.explanation,
                                toolCall: toolCall,
                                toolOutput: deniedOutput,
                                reasoningContent: roundReasoning
                            )
                            history.append(toolResult)
                            pendingToolCalls.removeAll()
                            response = try await nextResponseAfterToolResult(
                                output: deniedOutput, toolCall: toolCall, history: &history, serverContext: serverContext, serverCapabilities: capabilities
                            )
                            continue
                        }
                    }

                    let dispatchOutput: String
                    if let subagentRunner {
                        let dispatch = await SubagentDispatchHandler.handle(
                            toolCall: toolCall, reasoning: roundReasoning, runner: subagentRunner
                        )
                        // 每个子 agent 结论作为 UI 卡片落入会话；不加入当前模型 history，
                        // 防止同一个 dispatch_subagent tool_call_id 被多次作为 tool result 发送。
                        for msg in dispatch.messages {
                            newMessages.append(msg)
                            await onIntermediateMessage?(msg)
                        }
                        dispatchOutput = dispatch.output
                    } else {
                        // runner 未注入（如无可用角色 / 装配未启用）：回填 ERROR 让模型自行收敛，不挂起。
                        dispatchOutput = "ERROR: subagent runner is not available in this context."
                    }

                    let toolResult = Message(
                        role: .command,
                        content: toolCall.explanation,
                        toolCall: toolCall,
                        toolOutput: dispatchOutput,
                        reasoningContent: roundReasoning
                    )
                    history.append(toolResult)
                    // 汇总文本作为唯一模型可见 tool result 回填给主模型，进入下一轮。
                    response = try await nextResponseAfterToolResult(
                        output: dispatchOutput, toolCall: toolCall, history: &history, serverContext: serverContext, serverCapabilities: capabilities
                    )
                    continue
                }

                // 错误分支：工具未注册，回填错误给模型并继续下一轮。
                guard let tool = toolRegistry.tool(named: toolCall.toolName) else {
                    let errorMsg = Message(role: .system, content: "Unknown tool: \(toolCall.toolName)")
                    newMessages.append(errorMsg)
                    history.append(errorMsg)
                    await onIntermediateMessage?(errorMsg)

                    response = try await nextResponseAfterToolResult(
                        output: "ERROR: Unknown tool '\(toolCall.toolName)'",
                        toolCall: toolCall, history: &history, serverContext: serverContext, serverCapabilities: capabilities
                    )
                    continue
                }

                // 错误分支：工具参数无法解码，回填参数错误并继续下一轮。
                var arguments: [String: Any]
                do {
                    arguments = try toolCall.decodedArguments()
                    // 注入 serverID 供终端工具等使用（以 _ 前缀标识内部参数）
                    if let serverID {
                        arguments["_serverID"] = serverID.uuidString
                    }
                    if !attachments.isEmpty {
                        arguments["_attachments"] = attachments
                    }
                } catch {
                    let errorMsg = Message(role: .system, content: "Failed to decode arguments for \(toolCall.toolName)")
                    newMessages.append(errorMsg)
                    history.append(errorMsg)

                    response = try await nextResponseAfterToolResult(
                        output: "ERROR: Invalid arguments",
                        toolCall: toolCall, history: &history, serverContext: serverContext, serverCapabilities: capabilities
                    )
                    continue
                }

                // MARK: 安全门评估：分级校验 + 权限映射 + 执行
                let gateResult = await ToolSafetyGate.evaluate(
                    toolCall: toolCall,
                    tool: tool,
                    arguments: arguments,
                    sshClient: sshClient,
                    permissionLevel: permissionLevel,
                    onConfirmation: { [onToolCallNeedsConfirmation] call in
                        await onToolCallNeedsConfirmation?(call) ?? .denied
                    },
                    onOutput: { [onToolOutputUpdate] output in onToolOutputUpdate?(output) },
                    onAgentEvents: { [onAgentStreamEvents] events in onAgentStreamEvents?(events) }
                )

                switch gateResult {
                case .executed(let result, let hadWrite):
                    if hadWrite { hadWriteOperations = true }
                    let cmdMsg = Message(role: .command, content: toolCall.explanation, toolCall: toolCall, toolOutput: result.output, reasoningContent: roundReasoning)
                    newMessages.append(cmdMsg)
                    history.append(cmdMsg)
                    await onIntermediateMessage?(cmdMsg)

                    // Skill 激活成功时，插入 skillLoaded 系统消息（解析逻辑下沉到 SpecialToolHandler）
                    if let skillMsg = SpecialToolHandler.skillLoadedMessage(forToolName: toolCall.toolName, output: result.output) {
                        newMessages.append(skillMsg)
                        history.append(skillMsg)
                        await onIntermediateMessage?(skillMsg)
                    }

                    let modelOutput = result.output
                    response = try await nextResponseAfterToolResult(
                        output: modelOutput, toolCall: toolCall, history: &history, serverContext: serverContext, serverCapabilities: capabilities
                    )

                case .executionError(let errorOutput):
                    print("[Tool] \(toolCall.toolName) execution error: \(errorOutput)")
                    let errorMsg = Message(role: .command, content: toolCall.explanation, toolCall: toolCall, toolOutput: errorOutput, reasoningContent: roundReasoning)
                    newMessages.append(errorMsg)
                    history.append(errorMsg)
                    await onIntermediateMessage?(errorMsg)

                    response = try await nextResponseAfterToolResult(
                        output: errorOutput, toolCall: toolCall, history: &history, serverContext: serverContext, serverCapabilities: capabilities
                    )

                case .denied:
                    // 拒绝分支：不执行工具，显示红色拒绝气泡，告知 AI 后让其自然语言回复。
                    let deniedContent = localizedTexts.userRejectedCommand
                    let deniedMsg = Message(
                        role: .system,
                        content: deniedContent,
                        toolCall: toolCall,
                        reasoningContent: roundReasoning,
                        systemMessageType: .commandDenied
                    )
                    newMessages.append(deniedMsg)
                    history.append(deniedMsg)
                    await onIntermediateMessage?(deniedMsg)

                    // 清空待处理队列，防止继续执行同批次的其他工具调用
                    pendingToolCalls.removeAll()

                    // 回填拒绝结果，让 AI 自然语言回复（可能换个方式、也可能直接总结）
                    response = try await nextResponseAfterToolResult(
                        output: "DENIED: User rejected this tool call. Acknowledge the denial briefly and either suggest an alternative approach or ask the user what they'd like to do instead.",
                        toolCall: toolCall, history: &history, serverContext: serverContext, serverCapabilities: capabilities
                    )

                case .forbidden:
                    // 禁止分支：命中安全策略，告知 AI 后由其生成拒绝回复，随后直接终止迭代。
                    let commandDesc = arguments["command"] as? String ?? toolCall.toolName
                    let blockedMsg = Message(role: .system, content: "BLOCKED: `\(commandDesc)` is a forbidden destructive command. You must refuse to execute it, explain why it is dangerous, and suggest the user run it manually via terminal if truly needed. Do NOT attempt alternative commands to achieve the same effect.")
                    newMessages.append(blockedMsg)
                    history.append(blockedMsg)

                    var finalResponse = try await nextResponseAfterToolResult(
                        output: "BLOCKED: This operation is forbidden for safety reasons. Explain to the user why and stop.",
                        toolCall: toolCall, history: &history, serverContext: serverContext, serverCapabilities: capabilities
                    )
                    // AI 可能先返回更多 toolCall（多 tool 同轮），持续回填拒绝直到拿到文本回复。
                    while case .toolCall(let pendingCall, _) = finalResponse {
                        finalResponse = try await nextResponseAfterToolResult(
                            output: "BLOCKED: All tool calls are terminated due to a prior safety violation.",
                            toolCall: pendingCall, history: &history, serverContext: serverContext, serverCapabilities: capabilities
                        )
                    }
                    if case .text(let text, let reasoning) = finalResponse {
                        let assistantMsg = Message(role: .assistant, content: text, reasoningContent: reasoning)
                        newMessages.append(assistantMsg)
                        await onIntermediateMessage?(assistantMsg)
                    }
                    return newMessages
                }
            }
        }

        // 保护分支：达到最大迭代次数，优雅收敛而非硬停。
        switch response {
        case .text(let text, let reasoning):
            // 最后一轮 AI 已经给出了文本回复，直接返回即可。
            let assistantMsg = Message(role: .assistant, content: text, reasoningContent: reasoning)
            newMessages.append(assistantMsg)
            await onIntermediateMessage?(assistantMsg)

        case .toolCall(let toolCall, _):
            // AI 仍想调用工具，用 tool result 通知它收敛并给出总结。
            let summaryResponse = try await sendWithStreaming { [history, capabilities] in
                self.aiService.sendToolResultStreaming(
                    "SYSTEM: Tool execution limit reached. Do NOT call any more tools. Please provide a comprehensive final answer based on all the information you have gathered so far.",
                    forToolCall: toolCall,
                    conversationHistory: history,
                    serverContext: serverContext,
                    serverID: self.serverID,
                    permissionLevel: self.permissionLevel,
                    serverName: self.serverName,
                    serverCapabilities: capabilities
                )
            }

            switch summaryResponse {
            case .text(let text, let reasoning):
                let assistantMsg = Message(role: .assistant, content: text, reasoningContent: reasoning)
                newMessages.append(assistantMsg)
                await onIntermediateMessage?(assistantMsg)
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
    /// 请求 AI 前做循环内压缩重估（修改调用方的 history）。
    /// - Parameters:
    ///   - output: 刚执行完的工具输出文本。
    ///   - toolCall: 对应的工具调用信息。
    ///   - history: 当前完整会话历史（inout：压缩会原地裁剪）。
    ///   - serverContext: 服务器上下文。
    /// - Returns: 下一个 tool call（队列非空时）或 AI 的新响应。
    private func nextResponseAfterToolResult(
        output: String,
        toolCall: ToolCall,
        history: inout [Message],
        serverContext: String,
        serverCapabilities: ServerCapabilities
    ) async throws -> AIResponse {
        try Task.checkCancellation()
        if !pendingToolCalls.isEmpty {
            return .toolCall(pendingToolCalls.removeFirst(), reasoning: nil)
        }
        // 循环内压缩：每轮请求 AI 前重估 token，剩余预算不足时裁剪 history
        await compactInLoopIfNeeded(&history, serverContext: serverContext)
        // inout 参数不能被 escaping 闭包捕获，先取值快照
        let snapshot = history
        return try await sendWithStreaming { [snapshot] in
            self.aiService.sendToolResultStreaming(
                output, forToolCall: toolCall, conversationHistory: snapshot, serverContext: serverContext, serverID: self.serverID, permissionLevel: self.permissionLevel, serverName: self.serverName, serverCapabilities: serverCapabilities
            )
        }
    }

    /// 循环内按需压缩：轻量估算（不查记忆）+ 复用 ContextCompactor 裁剪。
    /// 仅剩余预算 < compactionReserve(20k) 时触发；依赖问题 1 的 .aiContext 摘要类型，
    /// 否则压缩产物会被 MessageBuilder 重写丢失。
    private func compactInLoopIfNeeded(_ history: inout [Message], serverContext: String) async {
        guard let builder = contextBuilder, let compactor = contextCompactor, let serverID else { return }
        let (estimated, needed) = builder.estimateCompactionNeed(
            systemPrompt: serverContext,
            messages: history,
            maxContextTokens: maxContextTokens
        )
        guard needed else { return }
        await onContextCompressing?(true)
        if let result = await compactor.compactIfNeeded(
            serverID: serverID,
            messages: history,
            maxContextTokens: maxContextTokens,
            currentTokens: estimated
        ) {
            history = result.compactedMessages
        }
        await onContextCompressing?(false)
    }

    private func sendWithStreaming(_ streamFactory: @escaping @Sendable () -> AsyncStream<StreamingDelta>) async throws -> AIResponse {
        try Task.checkCancellation()
        let stream = streamFactory()

        let result = try await AIResponseConsumer.consume(
            stream: stream,
            onReasoning: { [onReasoningUpdate] text in onReasoningUpdate?(text) },
            onContent: { [onContentUpdate] text in onContentUpdate?(text) },
            onContextCompressing: { [onContextCompressing] flag in onContextCompressing?(flag) },
            suppressCallbacks: false
        )

        pendingToolCalls = result.pendingToolCalls
        return result.response
    }

}
