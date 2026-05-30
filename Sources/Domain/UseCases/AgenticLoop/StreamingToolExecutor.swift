/// 文件说明：StreamingToolExecutor，工具流式/非流式执行与超时管理。
import Foundation

/// LastActivityTracker：追踪最后活动时间，用于 idle 超时检测。
actor LastActivityTracker {
    private var lastTime: ContinuousClock.Instant = .now
    func touch() { lastTime = .now }
    func elapsed() -> Duration { ContinuousClock.Instant.now - lastTime }
}

/// StreamingToolExecutor：
/// 执行工具（流式/非流式），管理 idle 超时（30s）和总超时（600s），
/// 清理 ANSI 转义序列，增量解析 ACP 事件，节流 UI 回调（150ms）。
enum StreamingToolExecutor {

    /// 流式执行的兜底安全超时（秒）。
    private static let streamingTimeout: TimeInterval = 3600

    /// 非流式工具执行的超时（秒），防止无限阻塞。
    private static let nonStreamingToolTimeout: TimeInterval = 120

    /// 流式空闲超时：连续无数据（含心跳）超过此时间判定卡死。
    private static let streamingIdleTimeout: Duration = .seconds(30)

    /// 流式 UI 回调最小间隔（秒），避免高频 chunk 导致 SwiftUI 过度刷新。
    private static let uiThrottleInterval: TimeInterval = 0.15

    /// 执行工具，优先使用流式模式（若工具支持），否则回退到缓冲模式。
    /// - 流式路径带 30s 空闲超时 + 600s 总超时保护，并对 UI 回调做节流（≥150ms/次）。
    /// - Parameters:
    ///   - tool: 待执行的工具实例。
    ///   - arguments: 工具调用参数。
    ///   - sshClient: SSH 客户端，供工具执行远端命令。
    ///   - onOutput: 实时输出回调（累积文本）。
    ///   - onAgentEvents: ACP 编码代理流式事件批量回调。
    /// - Returns: 工具执行结果。
    /// - Throws: 工具执行失败或超时时抛出。
    static func execute(
        tool: ToolProtocol,
        arguments: [String: Any],
        sshClient: SSHClientProtocol,
        onOutput: @MainActor @escaping @Sendable (String) -> Void,
        onAgentEvents: @MainActor @escaping @Sendable ([AgentStreamEvent]) -> Void
    ) async throws -> ToolExecutionResult {
        try Task.checkCancellation()
        if tool.supportsStreaming,
           let stream = try await tool.executeStreaming(arguments: arguments, sshClient: sshClient) {
            return try await consumeStreamingWithTimeout(stream, onOutput: onOutput, onAgentEvents: onAgentEvents)
        } else {
            // 非流式工具带超时保护，防止无限阻塞
            return try await withThrowingTaskGroup(of: ToolExecutionResult.self) { group in
                group.addTask {
                    let result = try await tool.execute(arguments: arguments, sshClient: sshClient)
                    let cleaned = ToolExecutionResult(
                        output: result.output.strippingANSIEscapes(),
                        isSuccess: result.isSuccess
                    )
                    await onOutput(cleaned.output)
                    return cleaned
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(nonStreamingToolTimeout))
                    throw SSHError.timeout
                }
                guard let result = try await group.next() else {
                    throw SSHError.commandFailed("No result")
                }
                group.cancelAll()
                return result
            }
        }
    }

    /// 消费流式工具输出，附带空闲超时守卫、总超时守卫与 UI 节流。
    /// 心跳空字符串重置空闲计时器但不追加到输出。
    private static func consumeStreamingWithTimeout(
        _ stream: AsyncThrowingStream<String, Error>,
        onOutput: @MainActor @escaping @Sendable (String) -> Void,
        onAgentEvents: @MainActor @escaping @Sendable ([AgentStreamEvent]) -> Void
    ) async throws -> ToolExecutionResult {
        let lastActivity = LastActivityTracker()

        return try await withThrowingTaskGroup(of: ToolExecutionResult.self) { group in
            // 任务 1：消费流式输出（带节流 + ACP 事件增量解析）
            group.addTask {
                var accumulated = ""
                var lastUpdateTime: ContinuousClock.Instant = .now - .seconds(1)
                var parser = ACPStreamParser()
                var pendingEvents: [AgentStreamEvent] = []

                for try await chunk in stream {
                    await lastActivity.touch()
                    // 空字符串是心跳 keepalive，不追加到输出
                    guard !chunk.isEmpty else { continue }
                    let stripped = chunk.strippingANSIEscapes()
                    accumulated += stripped

                    // 增量解析 ACP 事件：只传新到达的片段（parser 内部维护残留行缓冲，O(N)）
                    let newEvents = parser.parse(chunk: stripped)
                    pendingEvents.append(contentsOf: newEvents)

                    let now = ContinuousClock.Instant.now
                    if now - lastUpdateTime >= .milliseconds(150) {
                        if !pendingEvents.isEmpty {
                            await onAgentEvents(pendingEvents)
                            pendingEvents.removeAll()
                        }
                        await onOutput(accumulated)
                        lastUpdateTime = now
                    }
                }
                // 流结束：flush 剩余
                if !pendingEvents.isEmpty {
                    await onAgentEvents(pendingEvents)
                }
                await onOutput(accumulated)
                return ToolExecutionResult(output: accumulated)
            }

            // 任务 2：空闲超时守卫（每 5s 检查一次最后活跃时间）
            let idleLimit = streamingIdleTimeout
            group.addTask {
                while true {
                    try await Task.sleep(for: .seconds(5))
                    let elapsed = await lastActivity.elapsed()
                    if elapsed >= idleLimit {
                        throw SSHError.timeout
                    }
                }
            }

            // 任务 3：总超时守卫
            let totalLimit = streamingTimeout
            group.addTask {
                try await Task.sleep(for: .seconds(totalLimit))
                throw SSHError.timeout
            }

            guard let result = try await group.next() else {
                throw SSHError.commandFailed("No result")
            }
            group.cancelAll()
            return result
        }
    }
}
