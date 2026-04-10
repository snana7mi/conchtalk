/// 文件说明：AIResponseConsumer，消费 AI 流式响应并解析结果。
import Foundation

/// AIResponseConsumer：
/// 消费 AI 流式响应流，累积 reasoning 和 content 文本，
/// 处理 tool call 排队，支持 UI 回调节流（150ms）。
nonisolated enum AIResponseConsumer {

    /// 消费结果。
    struct ConsumeResult: Sendable {
        let response: AIResponse
        let pendingToolCalls: [ToolCall]
    }

    /// 消费流式响应直到结束。
    /// - Parameters:
    ///   - stream: AI 流式响应事件流。
    ///   - onReasoning: 推理文本累积回调（传递当前累积全文）。
    ///   - onContent: 正文文本累积回调（传递当前累积全文）。
    ///   - onContextCompressing: 上下文压缩状态变化回调。
    ///   - suppressCallbacks: 为 true 时跳过所有 UI 回调。
    /// - Returns: 消费结果，包含首个响应和待处理的 tool call 队列。
    /// - Throws: 当流中收到 `.error` 事件时抛出对应错误。
    static func consume(
        stream: AsyncStream<StreamingDelta>,
        onReasoning: @MainActor @Sendable (String) -> Void,
        onContent: @MainActor @Sendable (String) -> Void,
        onContextCompressing: @MainActor @Sendable (Bool) -> Void,
        suppressCallbacks: Bool
    ) async throws -> ConsumeResult {
        try Task.checkCancellation()

        var accumulatedReasoning = ""
        var accumulatedContent = ""
        var resultToolCalls: [ToolCall] = []
        var isCompressing = false

        // 节流：统一为 150ms（~6.7 次/秒），视觉流畅且降低 SwiftUI 布局压力
        var lastReasoningPushTime: ContinuousClock.Instant = .now - .seconds(1)
        var lastContentPushTime: ContinuousClock.Instant = .now - .seconds(1)

        for await delta in stream {
            try Task.checkCancellation()
            switch delta {
            case .reasoning(let chunk):
                if isCompressing {
                    isCompressing = false
                    await onContextCompressing(false)
                }
                accumulatedReasoning += chunk
                if !suppressCallbacks {
                    let now = ContinuousClock.Instant.now
                    if now - lastReasoningPushTime >= .milliseconds(150) {
                        await onReasoning(accumulatedReasoning)
                        lastReasoningPushTime = now
                    }
                }
            case .content(let chunk):
                if isCompressing {
                    isCompressing = false
                    await onContextCompressing(false)
                }
                accumulatedContent += chunk
                if !suppressCallbacks {
                    let now = ContinuousClock.Instant.now
                    if now - lastContentPushTime >= .milliseconds(150) {
                        await onContent(accumulatedContent)
                        lastContentPushTime = now
                    }
                }
            case .toolCall(let toolCall):
                if isCompressing {
                    isCompressing = false
                    await onContextCompressing(false)
                }
                resultToolCalls.append(toolCall)
            case .contextCompressing:
                isCompressing = true
                await onContextCompressing(true)
            case .done:
                if isCompressing {
                    isCompressing = false
                    await onContextCompressing(false)
                }
                break
            case .error(let error):
                if isCompressing {
                    await onContextCompressing(false)
                }
                throw error
            }
        }

        // 流结束后推送最终完整文本，确保末尾 token 不因节流被丢弃
        if !suppressCallbacks {
            if !accumulatedReasoning.isEmpty { await onReasoning(accumulatedReasoning) }
            if !accumulatedContent.isEmpty { await onContent(accumulatedContent) }
        }

        let reasoning: String? = accumulatedReasoning.isEmpty ? nil : accumulatedReasoning

        if !resultToolCalls.isEmpty {
            // 首个 tool call 立即返回，其余存入待处理队列
            let pending = Array(resultToolCalls.dropFirst())
            return ConsumeResult(
                response: .toolCall(resultToolCalls[0], reasoning: reasoning),
                pendingToolCalls: pending
            )
        }

        // 避免向 UI 持久化空 assistant 气泡。
        // 1) 有 reasoning 但无 content：通常是 token 被 reasoning 耗尽。
        // 2) content / reasoning 都为空：模型或网关给了空完成包。
        let finalContent: String
        if accumulatedContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if reasoning != nil {
                finalContent = "[The model used all available tokens for reasoning and produced no visible reply. Try sending the message again or switching to a different model.]"
                print("[AIResponseConsumer] Empty content with reasoning present — likely token exhaustion")
            } else {
                finalContent = "[The model returned no visible reply. Try sending the message again.]"
                print("[AIResponseConsumer] Empty content and reasoning received from streaming response")
            }
        } else {
            finalContent = accumulatedContent
        }
        return ConsumeResult(
            response: .text(finalContent, reasoning: reasoning),
            pendingToolCalls: []
        )
    }
}
