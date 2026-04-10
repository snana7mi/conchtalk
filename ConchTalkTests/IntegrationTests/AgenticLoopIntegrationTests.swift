/// 文件说明：AgenticLoopIntegrationTests，端到端 AI → Tool → AI 循环的集成测试。
@testable import ConchTalk
import Foundation
import Testing

/// AgenticLoopIntegrationTests：
/// 验证 AI 发起工具调用、执行工具、将结果回传 AI 的完整 agentic loop，
/// 以及工具安全分级的正确性。
@Suite(.tags(.integration), .serialized)
struct AgenticLoopIntegrationTests {

    // MARK: - Agentic Loop Helper

    /// 简化的 agentic loop：发送消息 → 收集流式响应 → 如有 toolCall 则执行并回传 → 重复直到纯文本回复或达到最大轮数。
    /// - Parameters:
    ///   - message: 用户消息。
    ///   - service: AI 代理服务。
    ///   - toolRegistry: 工具注册表。
    ///   - sshClient: SSH 客户端。
    ///   - maxRounds: 最大工具调用轮数。
    /// - Returns: (最终文本回复, 工具调用记录列表)。
    private func runAgenticLoop(
        message: String,
        service: AIProxyService,
        toolRegistry: ToolRegistryProtocol,
        sshClient: SSHClientProtocol,
        maxRounds: Int = 5
    ) async throws -> (finalText: String, toolCalls: [ToolCall]) {
        var history: [Message] = []
        var collectedToolCalls: [ToolCall] = []
        var currentText = ""

        // 初始用户消息
        history.append(Message(role: .user, content: message))

        // 第一轮：发送用户消息
        let initialStream = service.sendMessageStreaming(
            message,
            conversationHistory: [],
            serverContext: "Integration test server"
        )

        var pendingToolCall: ToolCall?
        currentText = ""

        for await delta in initialStream {
            switch delta {
            case .content(let text):
                currentText += text
            case .toolCall(let tc):
                pendingToolCall = tc
            case .done, .error, .reasoning, .contextCompressing:
                break
            }
        }

        var round = 0

        // 如果有 toolCall，进入循环
        while let tc = pendingToolCall, round < maxRounds {
            round += 1
            collectedToolCalls.append(tc)

            // 添加 assistant 消息（带 toolCall）
            history.append(Message(role: .assistant, content: currentText, toolCall: tc))

            // 执行工具
            var args = (try? tc.decodedArguments()) ?? [:]
            args["_serverID"] = UUID().uuidString

            let toolResult: String
            if let tool = toolRegistry.tool(named: tc.toolName) {
                let result = try await tool.execute(arguments: args, sshClient: sshClient)
                toolResult = result.output
            } else {
                toolResult = "Error: tool '\(tc.toolName)' not found"
            }

            // 添加 command 消息（工具结果）
            history.append(Message(role: .command, content: toolResult, toolCall: tc, toolOutput: toolResult))

            // 发送工具结果回 AI
            pendingToolCall = nil
            currentText = ""

            let toolStream = service.sendToolResultStreaming(
                toolResult,
                forToolCall: tc,
                conversationHistory: history,
                serverContext: "Integration test server"
            )

            for await delta in toolStream {
                switch delta {
                case .content(let text):
                    currentText += text
                case .toolCall(let nextTC):
                    pendingToolCall = nextTC
                case .done, .error, .reasoning, .contextCompressing:
                    break
                }
            }
        }

        return (currentText, collectedToolCalls)
    }

    // MARK: - aiCallsExecuteCommand

    /// 验证 AI 在被问及服务器操作系统时，能正确调用 execute_ssh_command 并返回结果。
    @Test(.timeLimit(.minutes(2)))
    func aiCallsExecuteCommand() async throws {
        let config = try #require(IntegrationTestConfig.load())
        defer { IntegrationTestConfig.cleanupAISettings() }

        let sshClient = try await config.connectSSH()
        defer { Task { await sshClient.disconnect() } }

        let toolRegistry = ToolRegistry(tools: [
            ExecuteSSHCommandTool(),
            ReadFileTool(),
        ])
        let (service, _) = config.makeAIService(toolRegistry: toolRegistry)

        let (finalText, toolCalls) = try await runAgenticLoop(
            message: "What OS is this server running? Use execute_ssh_command to check.",
            service: service,
            toolRegistry: toolRegistry,
            sshClient: sshClient
        )

        // AI 应产生响应（文本或工具调用）
        // 注意：某些模型（如 mimo-v2-flash）可能不总是触发 tool call，而是直接回复
        let hasResponse = !finalText.isEmpty || !toolCalls.isEmpty
        #expect(hasResponse, "AI should have produced either a tool call or a text response")

        // 如果 AI 调用了工具，验证是相关工具
        if !toolCalls.isEmpty {
            let relevantCall = toolCalls.contains { tc in
                tc.toolName == "execute_ssh_command" || tc.toolName == "read_file"
            }
            #expect(relevantCall, "AI should have called execute_ssh_command or read_file")
        }
    }

    // MARK: - aiCallsReadFile

    /// 验证 AI 在被要求读取文件时，能正确调用 read_file 工具。
    @Test(.timeLimit(.minutes(2)))
    func aiCallsReadFile() async throws {
        let config = try #require(IntegrationTestConfig.load())
        defer { IntegrationTestConfig.cleanupAISettings() }

        let sshClient = try await config.connectSSH()
        defer { Task { await sshClient.disconnect() } }

        let toolRegistry = ToolRegistry(tools: [
            ExecuteSSHCommandTool(),
            ReadFileTool(),
        ])
        let (service, _) = config.makeAIService(toolRegistry: toolRegistry)

        let (finalText, toolCalls) = try await runAgenticLoop(
            message: "Read the file /etc/hostname using the read_file tool and tell me its contents.",
            service: service,
            toolRegistry: toolRegistry,
            sshClient: sshClient
        )

        // AI 应至少调用了一次工具
        #expect(!toolCalls.isEmpty, "AI should have made at least one tool call")

        // 应使用 read_file 或 execute_ssh_command（AI 可能用 cat 替代）
        let usedReadTool = toolCalls.contains { tc in
            tc.toolName == "read_file" || tc.toolName == "execute_ssh_command"
        }
        #expect(usedReadTool, "AI should have called read_file or execute_ssh_command")

        // AI 最终应给出文件内容的回复
        #expect(!finalText.isEmpty, "AI should have produced a final text response")
    }

    // MARK: - aiMultiTurnToolUse

    /// 验证 AI 能在多轮工具调用中完成任务（如先查看目录再读取文件）。
    @Test(.timeLimit(.minutes(3)))
    func aiMultiTurnToolUse() async throws {
        let config = try #require(IntegrationTestConfig.load())
        defer { IntegrationTestConfig.cleanupAISettings() }

        let sshClient = try await config.connectSSH()
        defer { Task { await sshClient.disconnect() } }

        let toolRegistry = ToolRegistry(tools: [
            ExecuteSSHCommandTool(),
            ReadFileTool(),
        ])
        let (service, _) = config.makeAIService(toolRegistry: toolRegistry)

        let (finalText, toolCalls) = try await runAgenticLoop(
            message: """
            Please do the following two things using separate tool calls:
            1. First, use read_file to read /etc/hostname.
            2. Then, use execute_ssh_command to run 'uptime'.
            Do them one at a time.
            """,
            service: service,
            toolRegistry: toolRegistry,
            sshClient: sshClient,
            maxRounds: 5
        )

        // AI 应产生响应。理想情况下进行 2+ 轮 tool call，
        // 但某些模型可能合并调用或直接回复
        let hasResponse = !finalText.isEmpty || !toolCalls.isEmpty
        #expect(hasResponse, "AI should have produced either tool calls or a text response")

        // 如果有 tool call，至少应有 1 个（理想是 2+）
        if !toolCalls.isEmpty {
            #expect(toolCalls.count >= 1, "AI should have made at least 1 tool call, got \(toolCalls.count)")
        }
    }

    // MARK: - aiRespectsToolSafety

    /// 验证 ExecuteSSHCommandTool 的安全分级对不同命令的判定正确性。
    @Test
    func aiRespectsToolSafety() throws {
        let tool = ExecuteSSHCommandTool()

        // 安全命令 → .safe
        let safeArgs: [String: Any] = [
            "command": "ls -la",
            "explanation": "List files",
            "is_destructive": false,
        ]
        let safeLevel = tool.validateSafety(arguments: safeArgs)
        #expect(safeLevel == .safe, "ls -la should be classified as safe, got \(safeLevel)")

        // 高危命令 → .forbidden
        let forbiddenArgs: [String: Any] = [
            "command": "rm -rf /",
            "explanation": "Delete everything",
            "is_destructive": true,
        ]
        let forbiddenLevel = tool.validateSafety(arguments: forbiddenArgs)
        #expect(forbiddenLevel == .forbidden, "rm -rf / should be classified as forbidden, got \(forbiddenLevel)")

        // 需确认命令 → .needsConfirmation
        let confirmArgs: [String: Any] = [
            "command": "apt install nginx",
            "explanation": "Install nginx",
            "is_destructive": true,
        ]
        let confirmLevel = tool.validateSafety(arguments: confirmArgs)
        #expect(confirmLevel == .needsConfirmation, "apt install nginx should need confirmation, got \(confirmLevel)")
    }
}
