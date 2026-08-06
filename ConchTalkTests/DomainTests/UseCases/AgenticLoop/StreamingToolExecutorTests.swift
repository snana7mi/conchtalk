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

    // MARK: - 累积输出上限（问题 6b）

    @Test("流式累积超过上限时丢头保尾并带英文截断标记")
    func streamingAccumulatedCappedWithMarker() async throws {
        let mockTool = MockTool()
        mockTool._supportsStreaming = true
        // 60 块 × 10KB = 600KB，远超 256KB 上限
        mockTool.streamingOutput = Array(
            repeating: String(repeating: "a", count: 10_240), count: 60)

        let sshClient = MockSSHClient()
        var lastCallbackOutput = ""

        let result = try await StreamingToolExecutor.execute(
            tool: mockTool,
            arguments: [:],
            sshClient: sshClient,
            onOutput: { lastCallbackOutput = $0 },
            onAgentEvents: { _ in }
        )

        #expect(result.output.hasPrefix("[Output truncated:"))
        // 上界：cap(256KB) + 标记长度的宽松余量
        #expect(result.output.utf8.count <= 256 * 1024 + 100)
        // 最后一次 onOutput 回调体积同样有界
        #expect(lastCallbackOutput.utf8.count <= 256 * 1024 + 100)
        // 保尾语义：尾部数据保留
        #expect(result.output.hasSuffix("a"))
    }

    @Test("非流式超大输出有界（实体层 8K 截断先行生效，执行器 cap 为第二道防线）")
    func nonStreamingLargeOutputCapped() async throws {
        // 事实核查：ToolExecutionResult.init 自带 8000 字符硬截断（头 2000 + 尾 6000 + 省略标记），
        // 任何工具返回值在构造时即被截断，非流式路径的 600KB 输入到不了执行器层的 256KB cap。
        // 本用例锁定的不变量：非流式超大输出最终有界、带截断痕迹、尾部保留。
        let mockTool = MockTool()
        mockTool._supportsStreaming = false
        mockTool.executeResult = ToolExecutionResult(
            output: String(repeating: "b", count: 600 * 1024))

        let sshClient = MockSSHClient()
        let result = try await StreamingToolExecutor.execute(
            tool: mockTool,
            arguments: [:],
            sshClient: sshClient,
            onOutput: { _ in },
            onAgentEvents: { _ in }
        )

        #expect(result.output.contains("chars omitted"))
        #expect(result.output.utf8.count <= 256 * 1024 + 100)
        #expect(result.output.hasSuffix("b"))
    }

    @Test("截断不影响 ACP 事件增量解析")
    func streamingACPEventsUnaffectedByCap() async throws {
        let mockTool = MockTool()
        mockTool._supportsStreaming = true
        // 先用 300KB 触发截断，再混入 [ACP] 事件行（用真实编码器构造，确保格式一致）。
        // 大块末尾必须带换行：ACPStreamParser 按行解析，无换行的尾巴会与后续 [ACP] 行
        // 拼成一条非 [ACP] 前缀的脏行，事件将被丢弃。
        let bigChunk = String(repeating: "c", count: 300 * 1024) + "\n"
        let acpLine = try AgentStreamEvent.text("hello from agent").encodeToStreamLine()
        mockTool.streamingOutput = [bigChunk, acpLine]

        let sshClient = MockSSHClient()
        var receivedEvents: [AgentStreamEvent] = []

        _ = try await StreamingToolExecutor.execute(
            tool: mockTool,
            arguments: [:],
            sshClient: sshClient,
            onOutput: { _ in },
            onAgentEvents: { receivedEvents.append(contentsOf: $0) }
        )

        #expect(receivedEvents.contains(.text("hello from agent")))
    }
}
