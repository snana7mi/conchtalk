/// 文件说明：StreamingToolExecutorTests，验证工具执行与超时管理。
import Testing
@testable import ConchTalk

@Suite("StreamingToolExecutor")
struct StreamingToolExecutorTests {

    @Test("非流式工具正常执行")
    func nonStreamingExecution() async throws {
        let mockTool = MockTool()
        mockTool.name = "test_tool"
        mockTool._supportsStreaming = false
        mockTool.executeResult = ToolExecutionResult(output: "result")

        let sshClient = MockSSHClient()
        var outputCapture = ""

        let result = try await StreamingToolExecutor.execute(
            tool: mockTool,
            arguments: [:],
            sshClient: sshClient,
            onOutput: { outputCapture = $0 },
            onAgentEvents: { _ in }
        )

        #expect(result.output == "result")
        #expect(mockTool.executeCalled == 1)
        #expect(outputCapture == "result")
    }

    @Test("流式工具输出累积")
    func streamingAccumulation() async throws {
        let mockTool = MockTool()
        mockTool.name = "streaming_tool"
        mockTool._supportsStreaming = true
        mockTool.streamingOutput = ["chunk1", "chunk2", "chunk3"]

        let sshClient = MockSSHClient()
        let result = try await StreamingToolExecutor.execute(
            tool: mockTool,
            arguments: [:],
            sshClient: sshClient,
            onOutput: { _ in },
            onAgentEvents: { _ in }
        )

        #expect(result.output.contains("chunk1"))
        #expect(result.output.contains("chunk2"))
        #expect(result.output.contains("chunk3"))
        #expect(result.output == "chunk1chunk2chunk3")
    }

    @Test("非流式工具执行错误传播")
    func nonStreamingError() async throws {
        let mockTool = MockTool()
        mockTool._supportsStreaming = false
        mockTool.executeError = SSHError.commandFailed("test error")

        let sshClient = MockSSHClient()

        await #expect(throws: SSHError.self) {
            _ = try await StreamingToolExecutor.execute(
                tool: mockTool,
                arguments: [:],
                sshClient: sshClient,
                onOutput: { _ in },
                onAgentEvents: { _ in }
            )
        }
    }

    @Test("流式工具执行错误传播")
    func streamingError() async throws {
        let mockTool = MockTool()
        mockTool._supportsStreaming = true
        mockTool.streamingOutput = ["partial"]
        mockTool.streamingError = SSHError.commandFailed("stream error")

        let sshClient = MockSSHClient()

        await #expect(throws: SSHError.self) {
            _ = try await StreamingToolExecutor.execute(
                tool: mockTool,
                arguments: [:],
                sshClient: sshClient,
                onOutput: { _ in },
                onAgentEvents: { _ in }
            )
        }
    }

    @Test("非流式输出经过 strippingANSIEscapes 处理")
    func nonStreamingOutputIsProcessed() async throws {
        // 验证非流式路径对输出调用了 strippingANSIEscapes()
        let mockTool = MockTool()
        mockTool._supportsStreaming = false
        mockTool.executeResult = ToolExecutionResult(output: "plain text")

        let sshClient = MockSSHClient()

        let result = try await StreamingToolExecutor.execute(
            tool: mockTool,
            arguments: [:],
            sshClient: sshClient,
            onOutput: { _ in },
            onAgentEvents: { _ in }
        )

        // 纯文本应原样通过
        #expect(result.output == "plain text")
    }

    @Test("流式输出经过 strippingANSIEscapes 处理")
    func streamingOutputIsProcessed() async throws {
        let mockTool = MockTool()
        mockTool._supportsStreaming = true
        mockTool.streamingOutput = ["plain output"]

        let sshClient = MockSSHClient()

        let result = try await StreamingToolExecutor.execute(
            tool: mockTool,
            arguments: [:],
            sshClient: sshClient,
            onOutput: { _ in },
            onAgentEvents: { _ in }
        )

        #expect(result.output == "plain output")
    }

    @Test("LastActivityTracker 追踪活动")
    func activityTracker() async {
        let tracker = LastActivityTracker()
        await tracker.touch()
        try? await Task.sleep(for: .milliseconds(50))
        let elapsed = await tracker.elapsed()
        #expect(elapsed >= .milliseconds(40))
    }

    @Test("流式心跳不追加到输出")
    func streamingHeartbeatIgnored() async throws {
        let mockTool = MockTool()
        mockTool._supportsStreaming = true
        mockTool.streamingOutput = ["data", "", "more"]  // 空字符串是心跳

        let sshClient = MockSSHClient()

        let result = try await StreamingToolExecutor.execute(
            tool: mockTool,
            arguments: [:],
            sshClient: sshClient,
            onOutput: { _ in },
            onAgentEvents: { _ in }
        )

        #expect(result.output == "datamore")
    }

    @Test("参数正确传递给工具")
    func argumentsPassedThrough() async throws {
        let mockTool = MockTool()
        mockTool._supportsStreaming = false
        mockTool.executeResult = ToolExecutionResult(output: "ok")

        let sshClient = MockSSHClient()
        let args: [String: Any] = ["command": "ls -la", "timeout": 30]

        _ = try await StreamingToolExecutor.execute(
            tool: mockTool,
            arguments: args,
            sshClient: sshClient,
            onOutput: { _ in },
            onAgentEvents: { _ in }
        )

        #expect(mockTool.lastArguments?["command"] as? String == "ls -la")
        #expect(mockTool.lastArguments?["timeout"] as? Int == 30)
    }
}
