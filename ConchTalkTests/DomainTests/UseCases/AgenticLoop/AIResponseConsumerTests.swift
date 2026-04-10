/// 文件说明：AIResponseConsumerTests，验证 AI 流式响应消费逻辑。
import Testing
@testable import ConchTalk

@Suite("AIResponseConsumer")
struct AIResponseConsumerTests {

    @Test("消费纯文本响应")
    func consumeTextResponse() async throws {
        let stream = AsyncStream<StreamingDelta> { continuation in
            continuation.yield(.content("Hello"))
            continuation.yield(.content(" world"))
            continuation.yield(.done)
            continuation.finish()
        }

        var lastContent = ""
        let result = try await AIResponseConsumer.consume(
            stream: stream,
            onReasoning: { _ in },
            onContent: { lastContent = $0 },
            onContextCompressing: { _ in },
            suppressCallbacks: false
        )

        if case .text(let text, _) = result.response {
            #expect(text == "Hello world")
        } else {
            Issue.record("Expected text response")
        }
        #expect(result.pendingToolCalls.isEmpty)
        #expect(lastContent == "Hello world")
    }

    @Test("消费 reasoning + content 响应")
    func consumeReasoningAndContent() async throws {
        let stream = AsyncStream<StreamingDelta> { continuation in
            continuation.yield(.reasoning("thinking..."))
            continuation.yield(.content("answer"))
            continuation.yield(.done)
            continuation.finish()
        }

        let result = try await AIResponseConsumer.consume(
            stream: stream,
            onReasoning: { _ in },
            onContent: { _ in },
            onContextCompressing: { _ in },
            suppressCallbacks: false
        )

        if case .text(let text, let reasoning) = result.response {
            #expect(text == "answer")
            #expect(reasoning == "thinking...")
        } else {
            Issue.record("Expected text response with reasoning")
        }
    }

    @Test("消费 tool call 响应")
    func consumeToolCall() async throws {
        let toolCall = TestFixtures.makeToolCall(toolName: "execute_ssh_command")
        let stream = AsyncStream<StreamingDelta> { continuation in
            continuation.yield(.reasoning("thinking"))
            continuation.yield(.toolCall(toolCall))
            continuation.yield(.done)
            continuation.finish()
        }

        let result = try await AIResponseConsumer.consume(
            stream: stream,
            onReasoning: { _ in },
            onContent: { _ in },
            onContextCompressing: { _ in },
            suppressCallbacks: false
        )

        if case .toolCall(let tc, let reasoning) = result.response {
            #expect(tc.toolName == "execute_ssh_command")
            #expect(reasoning == "thinking")
        } else {
            Issue.record("Expected toolCall")
        }
        #expect(result.pendingToolCalls.isEmpty)
    }

    @Test("多个 tool call 排队")
    func multipleToolCalls() async throws {
        let tc1 = TestFixtures.makeToolCall(id: "call_1", toolName: "ls")
        let tc2 = TestFixtures.makeToolCall(id: "call_2", toolName: "cat")
        let stream = AsyncStream<StreamingDelta> { continuation in
            continuation.yield(.toolCall(tc1))
            continuation.yield(.toolCall(tc2))
            continuation.yield(.done)
            continuation.finish()
        }

        let result = try await AIResponseConsumer.consume(
            stream: stream,
            onReasoning: { _ in },
            onContent: { _ in },
            onContextCompressing: { _ in },
            suppressCallbacks: false
        )

        if case .toolCall(let tc, _) = result.response {
            #expect(tc.toolName == "ls")
        } else {
            Issue.record("Expected first toolCall")
        }
        #expect(result.pendingToolCalls.count == 1)
        #expect(result.pendingToolCalls[0].toolName == "cat")
    }

    @Test("suppressCallbacks 不调回调")
    func suppressCallbacks() async throws {
        let stream = AsyncStream<StreamingDelta> { continuation in
            continuation.yield(.reasoning("think"))
            continuation.yield(.content("hello"))
            continuation.yield(.contextCompressing)
            continuation.yield(.done)
            continuation.finish()
        }

        var called = false
        _ = try await AIResponseConsumer.consume(
            stream: stream,
            onReasoning: { _ in called = true },
            onContent: { _ in called = true },
            onContextCompressing: { _ in },
            suppressCallbacks: true
        )

        #expect(!called)
    }

    @Test("流中错误抛出")
    func streamError() async {
        let stream = AsyncStream<StreamingDelta> { continuation in
            continuation.yield(.error(AIServiceError.invalidResponse))
            continuation.finish()
        }

        do {
            _ = try await AIResponseConsumer.consume(
                stream: stream,
                onReasoning: { _ in },
                onContent: { _ in },
                onContextCompressing: { _ in },
                suppressCallbacks: false
            )
            Issue.record("Should throw")
        } catch {
            // Expected
        }
    }

    @Test("空 content 有 reasoning 时使用占位文案")
    func emptyContentWithReasoning() async throws {
        let stream = AsyncStream<StreamingDelta> { continuation in
            continuation.yield(.reasoning("deep thinking"))
            continuation.yield(.done)
            continuation.finish()
        }

        let result = try await AIResponseConsumer.consume(
            stream: stream,
            onReasoning: { _ in },
            onContent: { _ in },
            onContextCompressing: { _ in },
            suppressCallbacks: false
        )

        if case .text(let text, let reasoning) = result.response {
            #expect(text.contains("all available tokens for reasoning"))
            #expect(reasoning == "deep thinking")
        } else {
            Issue.record("Expected text response with placeholder")
        }
    }

    @Test("空 content 无 reasoning 时使用兜底文案")
    func emptyContentNoReasoning() async throws {
        let stream = AsyncStream<StreamingDelta> { continuation in
            continuation.yield(.done)
            continuation.finish()
        }

        let result = try await AIResponseConsumer.consume(
            stream: stream,
            onReasoning: { _ in },
            onContent: { _ in },
            onContextCompressing: { _ in },
            suppressCallbacks: false
        )

        if case .text(let text, let reasoning) = result.response {
            #expect(text.contains("no visible reply"))
            #expect(reasoning == nil)
        } else {
            Issue.record("Expected text response with fallback")
        }
    }

    @Test("contextCompressing 事件正确回调")
    func contextCompressingCallbacks() async throws {
        let stream = AsyncStream<StreamingDelta> { continuation in
            continuation.yield(.contextCompressing)
            continuation.yield(.content("compressed reply"))
            continuation.yield(.done)
            continuation.finish()
        }

        var compressingStates: [Bool] = []
        let result = try await AIResponseConsumer.consume(
            stream: stream,
            onReasoning: { _ in },
            onContent: { _ in },
            onContextCompressing: { flag in compressingStates.append(flag) },
            suppressCallbacks: false
        )

        // 应先收到 true（开始压缩），再收到 false（content 到达时结束压缩）
        #expect(compressingStates == [true, false])
        if case .text(let text, _) = result.response {
            #expect(text == "compressed reply")
        } else {
            Issue.record("Expected text response")
        }
    }
}
