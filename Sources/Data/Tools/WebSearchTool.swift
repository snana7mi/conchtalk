/// 文件说明：WebSearchTool，使用用户选择的搜索服务直连搜索互联网。
import Foundation

/// WebSearchTool：
/// 仅在用户启用并配置当前搜索服务 API Key 时向 AI 暴露。
/// 请求由 App 直接发送给用户选择的提供商，不经过 ConchTalk 服务或 SSH 服务器。
nonisolated struct WebSearchTool: ToolProtocol, @unchecked Sendable {
    let name = "web_search"
    let description = """
        Search the live web with the user's configured search provider. Returns source titles, URLs, snippets, and publication dates when available. Use it for current information or facts that need web verification. Use web_fetch on a returned public URL when the full page content is needed.
        """

    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "query": [
                "type": "string",
                "description": "Search query (maximum 400 characters and 50 words)",
            ] as [String: String],
            "country": [
                "type": "string",
                "description": "Optional 2-letter country code for result origin, such as US, CN, or JP",
            ] as [String: String],
            "search_lang": [
                "type": "string",
                "description": "Optional result language code, such as en, zh-CN, or ja",
            ] as [String: String],
            "freshness": [
                "type": "string",
                "description": "Optional age filter supported by Brave and Tavily: pd, pw, pm, py, or YYYY-MM-DDtoYYYY-MM-DD",
            ] as [String: String],
            "count": [
                "type": "integer",
                "description": "Number of web results from 1 to 20; defaults to 5",
            ] as [String: String],
        ] as [String: Any],
        "required": ["query"],
    ]

    private let settingsProvider: @Sendable () -> WebSearchSettings
    private let session: URLSession

    init(keychainService: KeychainServiceProtocol, session: URLSession = .shared) {
        self.settingsProvider = {
            WebSearchSettings.load(keychainService: keychainService)
        }
        self.session = session
    }

    /// 测试与独立装配入口，允许注入固定配置而不触碰全局偏好。
    init(
        settingsProvider: @escaping @Sendable () -> WebSearchSettings,
        session: URLSession = .shared
    ) {
        self.settingsProvider = settingsProvider
        self.session = session
    }

    var isAvailable: Bool { settingsProvider().isConfigured }

    /// 联网搜索为纯读取操作，无远端系统副作用。
    func validateSafety(arguments: [String: Any]) -> SafetyLevel { .safe }

    func execute(
        arguments: [String: Any],
        sshClient: SSHClientProtocol
    ) async throws -> ToolExecutionResult {
        let settings = settingsProvider()
        guard settings.isEnabled else {
            throw ToolError.executionFailed("Web search is disabled in Settings")
        }
        let apiKey = settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            throw ToolError.executionFailed("Search API key is missing")
        }

        let query = try Self.validatedQuery(from: arguments)
        let client = WebSearchProviderClientFactory.make(for: settings.provider)
        let request = try client.makeRequest(query: query, apiKey: apiKey)
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ToolError.executionFailed(
                "Invalid HTTP response from \(settings.provider.displayName)"
            )
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let detail = Self.errorDetail(from: data)
            return ToolExecutionResult(
                output: "\(settings.provider.displayName) search failed (HTTP \(httpResponse.statusCode)): \(detail)",
                isSuccess: false
            )
        }
        return ToolExecutionResult(output: try client.formatResponse(data))
    }

    /// 验证提供商共享的参数，并统一清理可选字符串。
    private static func validatedQuery(from arguments: [String: Any]) throws -> WebSearchQuery {
        guard let rawQuery = arguments["query"] as? String else {
            throw ToolError.missingParameter("query")
        }
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            throw ToolError.invalidArguments("query must not be empty")
        }
        guard query.count <= 400, query.split(whereSeparator: \.isWhitespace).count <= 50 else {
            throw ToolError.invalidArguments("query must not exceed 400 characters or 50 words")
        }

        func optionalString(_ key: String) -> String? {
            guard let value = arguments[key] as? String else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return WebSearchQuery(
            text: query,
            country: optionalString("country"),
            language: optionalString("search_lang"),
            freshness: optionalString("freshness"),
            count: min(max(arguments["count"] as? Int ?? 5, 1), 20)
        )
    }

    /// 优先提取结构化错误信息，并限制长度防止异常响应污染上下文。
    private static func errorDetail(from data: Data) -> String {
        if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["message", "detail", "error"] {
                if let value = root[key] as? String, !value.isEmpty {
                    return String(value.prefix(1_000))
                }
            }
        }
        let fallback = String(data: data, encoding: .utf8) ?? "Unknown error"
        return String(fallback.prefix(1_000))
    }
}
