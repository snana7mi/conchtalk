/// 文件说明：StreamingExecutor，执行流式 AI 请求，含自愈重试与连接恢复。
import Foundation

/// 自愈方向：补 reasoning_content 还是去掉。
nonisolated enum ReasoningHealingHint: Sendable, Equatable {
    case add, remove
}

/// 流式自愈预检结果。
enum StreamingPreflightResult: Sendable {
    case stream(URLSession.AsyncBytes, HTTPURLResponse)
    case needsRetry(ReasoningHealingHint)
    case error(Error)
}

/// StreamingExecutor：
/// 执行流式 AI 请求，处理 400 自愈（reasoning_content）、401 token 刷新和 -1005 连接重试。
nonisolated struct StreamingExecutor: @unchecked Sendable {
    private let session: URLSession

    init(session: URLSession) {
        self.session = session
    }

    // MARK: - Streaming with Healing

    /// 构建流式请求并发起连接。400 且匹配 reasoning 错误时返回 `.needsRetry`，401 时自动刷新 token 重试。
    func executeWithHealing(
        messages: [[String: Any]],
        config: AIRequestConfig,
        toolDefinitions: [[String: Any]],
        authService: AuthServiceProtocol?,
        resolveNewConfig: (() async throws -> AIRequestConfig)? = nil,
        allowAuthRetry: Bool = true
    ) async -> StreamingPreflightResult {
        guard let url = URL(string: config.endpointURL) else {
            return .error(AIServiceError.invalidResponse)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        config.strategy.setAuthHeaders(on: &request, apiKey: config.apiKey)

        do {
            request.httpBody = try config.strategy.buildStreamingRequestBody(
                messages: messages,
                model: config.modelName,
                toolDefinitions: toolDefinitions
            )
        } catch {
            return .error(error)
        }

        do {
            let (bytes, response) = try await bytesWithRetry(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                var errorBytes: [UInt8] = []
                do {
                    for try await byte in bytes {
                        errorBytes.append(byte)
                    }
                } catch {
                    print("[AIProxy] Failed to read streaming error body: \(error)")
                }
                let errorData = Data(errorBytes)
                let apiError = config.strategy.parseError(data: errorData, statusCode: statusCode)

                // 400 自愈：检查是否 reasoning_content 相关
                if statusCode == 400,
                   case .apiError(_, let msg) = apiError,
                   let hint = Self.reasoningHealingHint(from: msg) {
                    print("[AIProxy] Streaming 400 self-healing: \(hint == .add ? "adding" : "removing") reasoning_content and retrying…")
                    return .needsRetry(hint)
                }

                // 401 自动刷新 token 并重试
                if statusCode == 401, allowAuthRetry, let authService {
                    do {
                        print("[AIProxy] 401 received, refreshing access token…")
                        try await authService.refreshAccessToken()
                        if let resolveNewConfig {
                            let newConfig = try await resolveNewConfig()
                            return await executeWithHealing(messages: messages, config: newConfig, toolDefinitions: toolDefinitions, authService: authService, resolveNewConfig: resolveNewConfig, allowAuthRetry: false)
                        }
                    } catch {
                        print("[AIProxy] Token refresh failed: \(error)")
                        return .error(AuthError.sessionExpired)
                    }
                }

                return .error(apiError)
            }

            return .stream(bytes, httpResponse)
        } catch {
            return .error(error)
        }
    }

    // MARK: - Direct Streaming (no healing)

    /// 不带自愈的直接流式调用（用于重试时的第二次请求）。
    func executeDirect(
        messages: [[String: Any]],
        config: AIRequestConfig,
        toolDefinitions: [[String: Any]],
        continuation: AsyncStream<StreamingDelta>.Continuation
    ) async {
        guard let url = URL(string: config.endpointURL) else {
            continuation.yield(.error(AIServiceError.invalidResponse))
            continuation.finish()
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        config.strategy.setAuthHeaders(on: &request, apiKey: config.apiKey)

        do {
            request.httpBody = try config.strategy.buildStreamingRequestBody(
                messages: messages,
                model: config.modelName,
                toolDefinitions: toolDefinitions
            )
        } catch {
            continuation.yield(.error(error))
            continuation.finish()
            return
        }

        do {
            let (bytes, response) = try await bytesWithRetry(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                var errorBytes: [UInt8] = []
                do {
                    for try await byte in bytes {
                        errorBytes.append(byte)
                    }
                } catch {
                    print("[AIProxy] Failed to read streaming error body: \(error)")
                }
                let errorData = Data(errorBytes)
                let apiError = config.strategy.parseError(data: errorData, statusCode: statusCode)
                print("[AIProxy] Streaming retry failed (\(statusCode)): \(apiError.localizedDescription)")
                continuation.yield(.error(apiError))
                continuation.finish()
                return
            }

            await config.strategy.processSSEStream(bytes: bytes, continuation: continuation)
        } catch {
            continuation.yield(.error(error))
            continuation.finish()
        }
    }

    // MARK: - Retry for Connection Lost (-1005)

    /// 执行流式请求，并在连接中断（`-1005`）时按固定策略重试。
    /// - Parameters:
    ///   - request: 已构建的 HTTP 请求。
    ///   - maxRetries: 最大重试次数（默认 1）。
    /// - Returns: 流式字节序列与响应头。
    /// - Throws: 达到重试上限后抛出最后一次错误。
    /// - Retry Policy:
    ///   - 仅对 `URLError.networkConnectionLost` 重试。
    ///   - 重试间隔固定 500ms，不做指数退避。
    private func bytesWithRetry(for request: URLRequest, maxRetries: Int = 1) async throws -> (URLSession.AsyncBytes, URLResponse) {
        var lastError: Error?
        for attempt in 0...maxRetries {
            do {
                return try await session.bytes(for: request)
            } catch let error as URLError where error.code == .networkConnectionLost && attempt < maxRetries {
                lastError = error
                print("[AIProxy] Connection lost (-1005), retrying stream... (attempt \(attempt + 1))")
                try await Task.sleep(for: .milliseconds(500)) // throws on cancellation
            }
        }
        // maxRetries 为 0 或非重试类错误时 lastError 可能为 nil，兜底返回通用错误
        throw lastError ?? URLError(.unknown)
    }

    // MARK: - Self-Healing

    /// 从 400 错误信息中判断是否可以通过翻转 reasoning_content 策略自愈。
    static func reasoningHealingHint(from message: String) -> ReasoningHealingHint? {
        let lower = message.lowercased()
        // "Missing reasoning_content" 或 "Missing thinking block"
        if lower.contains("missing") && (lower.contains("reasoning_content") || lower.contains("thinking")) {
            return .add
        }
        if (lower.contains("reasoning_content") || lower.contains("thinking")) &&
            (lower.contains("not allowed") || lower.contains("invalid") || lower.contains("unexpected")) {
            return .remove
        }
        return nil
    }
}
