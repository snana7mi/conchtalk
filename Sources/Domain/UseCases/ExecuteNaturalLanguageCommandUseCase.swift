import Foundation

final class ExecuteNaturalLanguageCommandUseCase: @unchecked Sendable {
    private let aiService: AIServiceProtocol
    private let sshClient: SSHClientProtocol
    private let toolRegistry: ToolRegistryProtocol

    enum CommandApproval: Sendable {
        case approved
        case denied
    }

    // Callback for when a tool call needs user confirmation
    var onToolCallNeedsConfirmation: (@Sendable (ToolCall) async -> CommandApproval)?
    // Callback for streaming intermediate messages to UI
    var onIntermediateMessage: (@MainActor @Sendable (Message) -> Void)?
    // Streaming callbacks
    var onReasoningUpdate: (@MainActor @Sendable (String) -> Void)?
    var onContentUpdate: (@MainActor @Sendable (String) -> Void)?

    init(aiService: AIServiceProtocol, sshClient: SSHClientProtocol, toolRegistry: ToolRegistryProtocol) {
        self.aiService = aiService
        self.sshClient = sshClient
        self.toolRegistry = toolRegistry
    }

    func execute(userMessage: String, conversationHistory: [Message], serverContext: String) async throws -> [Message] {
        var newMessages: [Message] = []
        var history = conversationHistory
        var allAccumulatedReasoning = ""

        // Send user message to AI via streaming
        var response = try await sendWithStreaming { [history] in
            self.aiService.sendMessageStreaming(userMessage, conversationHistory: history, serverContext: serverContext)
        }

        // Agentic loop
        let maxIterations = 10
        var iteration = 0
        while iteration < maxIterations {
            iteration += 1

            switch response {
            case .text(let text, let reasoning):
                if let r = reasoning, !r.isEmpty {
                    if !allAccumulatedReasoning.isEmpty { allAccumulatedReasoning += "\n\n" }
                    allAccumulatedReasoning += r
                }
                let fullReasoning: String? = allAccumulatedReasoning.isEmpty ? nil : allAccumulatedReasoning
                let assistantMsg = Message(role: .assistant, content: text, reasoningContent: fullReasoning)
                newMessages.append(assistantMsg)
                onIntermediateMessage?(assistantMsg)
                return newMessages // Done!

            case .toolCall(let toolCall, let reasoning):
                if let r = reasoning, !r.isEmpty {
                    if !allAccumulatedReasoning.isEmpty { allAccumulatedReasoning += "\n\n" }
                    allAccumulatedReasoning += r
                }
                // Look up the tool
                guard let tool = toolRegistry.tool(named: toolCall.toolName) else {
                    let errorMsg = Message(role: .system, content: "Unknown tool: \(toolCall.toolName)")
                    newMessages.append(errorMsg)
                    history.append(errorMsg)
                    onIntermediateMessage?(errorMsg)

                    response = try await sendWithStreaming { [history] in
                        self.aiService.sendToolResultStreaming(
                            "ERROR: Unknown tool '\(toolCall.toolName)'",
                            forToolCall: toolCall, conversationHistory: history, serverContext: serverContext
                        )
                    }
                    continue
                }

                // Validate safety
                let arguments: [String: Any]
                do {
                    arguments = try toolCall.decodedArguments()
                } catch {
                    let errorMsg = Message(role: .system, content: "Failed to decode arguments for \(toolCall.toolName)")
                    newMessages.append(errorMsg)
                    history.append(errorMsg)

                    response = try await sendWithStreaming { [history] in
                        self.aiService.sendToolResultStreaming(
                            "ERROR: Invalid arguments",
                            forToolCall: toolCall, conversationHistory: history, serverContext: serverContext
                        )
                    }
                    continue
                }

                let safetyLevel = tool.validateSafety(arguments: arguments)

                switch safetyLevel {
                case .safe:
                    let result: ToolExecutionResult
                    do {
                        result = try await tool.execute(arguments: arguments, sshClient: sshClient)
                    } catch {
                        print("[Tool] \(toolCall.toolName) execution error: \(error)")
                        let errorOutput = "ERROR: \(error.localizedDescription)"
                        let errorMsg = Message(role: .command, content: toolCall.explanation, toolCall: toolCall, toolOutput: errorOutput)
                        newMessages.append(errorMsg)
                        history.append(errorMsg)
                        onIntermediateMessage?(errorMsg)

                        response = try await sendWithStreaming { [history] in
                            self.aiService.sendToolResultStreaming(
                                errorOutput, forToolCall: toolCall, conversationHistory: history, serverContext: serverContext
                            )
                        }
                        continue
                    }
                    let cmdMsg = Message(role: .command, content: toolCall.explanation, toolCall: toolCall, toolOutput: result.output)
                    newMessages.append(cmdMsg)
                    history.append(cmdMsg)
                    onIntermediateMessage?(cmdMsg)

                    response = try await sendWithStreaming { [history] in
                        self.aiService.sendToolResultStreaming(
                            result.output, forToolCall: toolCall, conversationHistory: history, serverContext: serverContext
                        )
                    }

                case .needsConfirmation:
                    let approval = await onToolCallNeedsConfirmation?(toolCall) ?? .denied

                    if approval == .approved {
                        let result: ToolExecutionResult
                        do {
                            result = try await tool.execute(arguments: arguments, sshClient: sshClient)
                        } catch {
                            print("[Tool] \(toolCall.toolName) execution error: \(error)")
                            let errorOutput = "ERROR: \(error.localizedDescription)"
                            let errorMsg = Message(role: .command, content: toolCall.explanation, toolCall: toolCall, toolOutput: errorOutput)
                            newMessages.append(errorMsg)
                            history.append(errorMsg)
                            onIntermediateMessage?(errorMsg)

                            response = try await sendWithStreaming { [history] in
                                self.aiService.sendToolResultStreaming(
                                    errorOutput, forToolCall: toolCall, conversationHistory: history, serverContext: serverContext
                                )
                            }
                            continue
                        }
                        let cmdMsg = Message(role: .command, content: toolCall.explanation, toolCall: toolCall, toolOutput: result.output)
                        newMessages.append(cmdMsg)
                        history.append(cmdMsg)
                        onIntermediateMessage?(cmdMsg)

                        response = try await sendWithStreaming { [history] in
                            self.aiService.sendToolResultStreaming(
                                result.output, forToolCall: toolCall, conversationHistory: history, serverContext: serverContext
                            )
                        }
                    } else {
                        let deniedMsg = Message(role: .system, content: "Tool call denied by user: \(toolCall.toolName)")
                        newMessages.append(deniedMsg)
                        history.append(deniedMsg)

                        response = try await sendWithStreaming { [history] in
                            self.aiService.sendToolResultStreaming(
                                "DENIED: User rejected this tool call",
                                forToolCall: toolCall, conversationHistory: history, serverContext: serverContext
                            )
                        }
                    }

                case .forbidden:
                    let blockedMsg = Message(role: .system, content: "Blocked dangerous tool call: \(toolCall.toolName)")
                    newMessages.append(blockedMsg)
                    history.append(blockedMsg)
                    onIntermediateMessage?(blockedMsg)

                    response = try await sendWithStreaming { [history] in
                        self.aiService.sendToolResultStreaming(
                            "BLOCKED: This operation is forbidden for safety reasons",
                            forToolCall: toolCall, conversationHistory: history, serverContext: serverContext
                        )
                    }
                }
            }
        }

        let timeoutMsg = Message(role: .system, content: "Reached maximum tool execution limit")
        newMessages.append(timeoutMsg)
        return newMessages
    }

    // MARK: - Streaming Helper

    /// Consume an AsyncStream<StreamingDelta>, calling reasoning/content callbacks for each chunk,
    /// and return the final AIResponse when done.
    private func sendWithStreaming(_ streamFactory: @escaping @Sendable () -> AsyncStream<StreamingDelta>) async throws -> AIResponse {
        let stream = streamFactory()

        var accumulatedReasoning = ""
        var accumulatedContent = ""
        var resultToolCall: ToolCall?

        for await delta in stream {
            switch delta {
            case .reasoning(let chunk):
                accumulatedReasoning += chunk
                onReasoningUpdate?(chunk)
            case .content(let chunk):
                accumulatedContent += chunk
                onContentUpdate?(chunk)
            case .toolCall(let toolCall):
                resultToolCall = toolCall
            case .done:
                break
            case .error(let error):
                throw error
            }
        }

        let reasoning: String? = accumulatedReasoning.isEmpty ? nil : accumulatedReasoning

        if let toolCall = resultToolCall {
            return .toolCall(toolCall, reasoning: reasoning)
        }

        return .text(accumulatedContent, reasoning: reasoning)
    }
}
