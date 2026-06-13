/// 文件说明：MockAIService，测试用 AI 服务模拟，支持流式响应序列配置与调用记录。
@testable import ConchTalk
import Foundation

/// MockAIService：
/// 实现 AIServiceProtocol 的测试替身，按顺序消费预配置的流式响应序列。
final class MockAIService: AIServiceProtocol, @unchecked Sendable {

    /// 保护并发可变状态（callHistory / streamingResponseIndex）。
    /// SubagentRunner 会从并行任务并发调用流式方法，需串行化读改写避免数据竞争。
    private let lock = NSLock()

    // MARK: - 调用记录

    struct CallRecord: Sendable {
        let method: String
        let message: String?
        /// 该次流式请求携带的会话历史（验证循环内压缩是否生效）。
        var history: [Message]? = nil
    }

    private(set) var callHistory: [CallRecord] = []

    // MARK: - 可配置行为

    /// 每次调用 sendMessageStreaming / sendToolResultStreaming 消费一组 delta。
    var streamingResponses: [[StreamingDelta]] = []
    private var streamingResponseIndex = 0

    /// generateMemorySummary 的返回值。
    var memorySummaryResult = MemorySummaryResult(conversationMemory: nil, serverMemory: nil, globalMemory: nil)
    var memorySummaryError: Error?

    /// sendSimpleMessage 的返回值。
    var simpleMessageResult: String = ""
    var simpleMessageError: Error?

    // MARK: - AIServiceProtocol

    func sendMessageStreaming(
        _ message: String,
        conversationHistory: [Message],
        serverContext: String,
        serverID: UUID?,
        permissionLevel: PermissionLevel,
        serverName: String,
        serverCapabilities: ServerCapabilities
    ) -> AsyncStream<StreamingDelta> {
        recordCall(CallRecord(method: "sendMessageStreaming", message: message, history: conversationHistory))
        return makeStream()
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
        recordCall(CallRecord(method: "sendToolResultStreaming", message: result, history: conversationHistory))
        return makeStream()
    }

    func generateMemorySummary(
        recentMessages: [Message],
        existingConversationMemory: String?,
        existingServerMemory: String?,
        existingGlobalMemory: String?
    ) async throws -> MemorySummaryResult {
        recordCall(CallRecord(method: "generateMemorySummary", message: nil))
        if let error = memorySummaryError { throw error }
        return memorySummaryResult
    }

    func sendSimpleMessage(_ prompt: String) async throws -> String {
        recordCall(CallRecord(method: "sendSimpleMessage", message: prompt))
        if let error = simpleMessageError { throw error }
        return simpleMessageResult
    }

    /// 设置后，makeStream 会在 yield 完 deltas 后 yield .error(CancellationError())。
    /// 用于模拟流式传输中途被取消的场景。
    var throwCancellationAfterYielding: Bool = false

    // MARK: - 内部辅助

    /// 线程安全地追加调用记录。
    private func recordCall(_ record: CallRecord) {
        lock.lock()
        callHistory.append(record)
        lock.unlock()
    }

    private func makeStream() -> AsyncStream<StreamingDelta> {
        // 锁内完成 index 读改写，避免并行子 agent 同时进入造成的越界与丢更新。
        lock.lock()
        let deltas: [StreamingDelta]
        if streamingResponseIndex < streamingResponses.count {
            deltas = streamingResponses[streamingResponseIndex]
            streamingResponseIndex += 1
        } else {
            deltas = [.done]
        }
        let shouldThrowCancellation = throwCancellationAfterYielding
        lock.unlock()
        return AsyncStream { continuation in
            for delta in deltas {
                continuation.yield(delta)
            }
            if shouldThrowCancellation {
                continuation.yield(.error(CancellationError()))
            }
            continuation.finish()
        }
    }

    // MARK: - 辅助方法

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        callHistory = []
        streamingResponses = []
        streamingResponseIndex = 0
        throwCancellationAfterYielding = false
        memorySummaryResult = MemorySummaryResult(conversationMemory: nil, serverMemory: nil, globalMemory: nil)
        memorySummaryError = nil
        simpleMessageResult = ""
        simpleMessageError = nil
    }

    func didCall(_ method: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return callHistory.contains { $0.method == method }
    }

    func callCount(_ method: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return callHistory.filter { $0.method == method }.count
    }
}
