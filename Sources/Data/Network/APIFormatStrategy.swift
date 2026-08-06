/// APIFormatStrategy：抽象不同 AI API 线上格式的差异。
/// Strategy 管三件事：Header 格式、请求体构造、响应解析。
/// URL 由用户配置决定，与 Strategy 无关。
import Foundation

nonisolated protocol APIFormatStrategy: Sendable {
    // MARK: - Headers

    /// 设置该格式所需的 HTTP 认证头。
    func setAuthHeaders(on request: inout URLRequest, apiKey: String)

    // MARK: - Request Body

    /// 构建流式请求体。
    func buildStreamingRequestBody(
        messages: [[String: Any]],
        model: String,
        toolDefinitions: [[String: Any]]
    ) throws -> Data

    /// 构建非流式请求体（标题生成、摘要等）。
    /// - Parameter reasoningEffort: 推理力度（"none"/"low"/"medium"/"high"），nil 表示不设置。
    func buildNonStreamingRequestBody(
        messages: [[String: Any]],
        model: String,
        maxTokens: Int?,
        temperature: Double?,
        reasoningEffort: String?
    ) throws -> Data

    // MARK: - Response Parsing

    /// 解析 SSE 流并 yield delta 事件。
    func processSSEStream(
        bytes: URLSession.AsyncBytes,
        continuation: AsyncStream<StreamingDelta>.Continuation
    ) async

    /// 解析非流式响应中的文本内容。
    func parseNonStreamingContent(from data: Data) throws -> String

    /// 解析错误响应。
    func parseError(data: Data, statusCode: Int) -> AIServiceError
}

/// 便利重载：不传 reasoningEffort 时默认为 nil。
extension APIFormatStrategy {
    nonisolated func buildNonStreamingRequestBody(
        messages: [[String: Any]],
        model: String,
        maxTokens: Int?,
        temperature: Double?
    ) throws -> Data {
        try buildNonStreamingRequestBody(
            messages: messages,
            model: model,
            maxTokens: maxTokens,
            temperature: temperature,
            reasoningEffort: nil
        )
    }
}
