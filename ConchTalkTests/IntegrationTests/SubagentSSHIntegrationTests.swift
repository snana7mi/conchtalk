/// 文件说明：SubagentSSHIntegrationTests，验证并行子 agent 经真实 Citadel exec channel 执行远端命令的稳定性。
@testable import ConchTalk
import Foundation
import Testing

/// SubagentSSHIntegrationTests：
/// 用状态驱动的脚本化 AI（每个子 agent 第一轮发 execute_ssh_command、第二轮回填结论）+ 真实 NIOSSHClient，
/// 在测试服务器上并发跑多个子 agent，验证计划最大风险项「Citadel 并发 exec channel 稳定性」。
/// 子 agent 间的真实 SSH 命令通过 maxConcurrent 限流并行执行，断言全部成功且结果保序。
@Suite(.tags(.integration), .serialized, .enabled(if: IntegrationTestConfig.isAvailable))
struct SubagentSSHIntegrationTests {

    /// 并发派发 5 个子 agent（maxConcurrent=2），每个在真实远端执行 `uname -s`，
    /// 验证：全部成功、各自拿到真实远端输出（Linux）、结果顺序与输入一致。
    @Test(.timeLimit(.minutes(2)))
    func parallelSubagentsRunRealSSH() async throws {
        let config = try #require(IntegrationTestConfig.load())
        let sshClient = try await config.connectSSH()
        defer { Task { await sshClient.disconnect() } }

        let ai = ScriptedSSHAIService(command: "uname -s")
        let registry = SubagentRegistry(preloaded: [
            SubagentDefinition(
                name: "general-purpose",
                description: "general",
                allowedTools: [],
                metadata: [:],
                systemPrompt: "you are general-purpose"
            )
        ])
        let runner = SubagentRunner(
            aiService: ai,
            sshClient: sshClient,
            baseToolRegistry: ToolRegistry(tools: [ExecuteSSHCommandTool()]),
            registry: registry,
            serverID: UUID(),
            permissionLevel: .permissive,
            serverContext: "Integration test server",
            approvalGate: SubagentApprovalGate(),
            parentConfirm: { _ in .denied },
            maxConcurrent: 2
        )

        let tasks = (0..<5).map { SubagentTask(subagentType: "general-purpose", prompt: "probe-\($0)") }
        let results = await runner.run(tasks: tasks)

        #expect(results.count == 5)
        #expect(results.allSatisfy { $0.succeeded })
        // 并发真实 exec channel：每个子 agent 都拿到了远端 `uname -s` 输出。
        #expect(results.allSatisfy { $0.outcome.contains("Linux") })
        // 保序不变式：结果顺序 == 输入顺序，不受并发完成顺序影响。
        #expect(results.map(\.task) == tasks.map(\.prompt))
    }
}

/// ScriptedSSHAIService：
/// 状态驱动脚本——首轮（sendMessageStreaming）恒发 execute_ssh_command，
/// 次轮（sendToolResultStreaming）恒把工具结果回填为纯文本结论以结束子 loop。
/// 不依赖共享可变 index，天然并发安全，适配 SubagentRunner 的并行调用。
private final class ScriptedSSHAIService: AIServiceProtocol, @unchecked Sendable {
    private let command: String

    init(command: String) {
        self.command = command
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
        let cmd = command
        return AsyncStream { continuation in
            let toolCall = TestFixtures.makeToolCall(
                id: UUID().uuidString,
                toolName: "execute_ssh_command",
                arguments: ["command": cmd, "explanation": "probe", "is_destructive": false]
            )
            continuation.yield(.toolCall(toolCall))
            continuation.yield(.done)
            continuation.finish()
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
            continuation.yield(.content(result))
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
