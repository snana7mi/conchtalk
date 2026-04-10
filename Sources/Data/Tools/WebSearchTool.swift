/// 文件说明：WebSearchTool，通过云端代理调用 Brave LLM Context API 搜索互联网。
import Foundation

/// WebSearchTool：
/// 仅云端代理模式可用的网页搜索工具。AI 决定何时需要搜索互联网，
/// 客户端将请求转发至云端代理，代理调用 Brave LLM Context API 并返回结果。
nonisolated struct WebSearchTool: ToolProtocol, @unchecked Sendable {
    let name = "web_search"
    let description = """
        Search the web and retrieve extracted content for grounding responses. \
        Returns pre-extracted text snippets from relevant web pages with source URLs. \
        Use this tool for accessing information beyond your knowledge cutoff. \
        IMPORTANT: Always use the current year in search queries when searching for \
        recent information, documentation, or current events.
        """

    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "query": [
                "type": "string",
                "description": "Search query (max 400 chars, 50 words)",
            ] as [String: String],
            "country": [
                "type": "string",
                "description": "2-char country code for result origin (e.g. US, CN, JP)",
            ] as [String: String],
            "search_lang": [
                "type": "string",
                "description": "Language preference for results (e.g. en, zh, ja)",
            ] as [String: String],
            "freshness": [
                "type": "string",
                "description": "Filter by age: pd=past day, pw=past week, pm=past month, py=past year, or YYYY-MM-DDtoYYYY-MM-DD",
            ] as [String: String],
            "count": [
                "type": "integer",
                "description": "Maximum number of results to consider (1-20, default 5)",
            ] as [String: String],
        ] as [String: Any],
        "required": ["query"],
    ]

    private static let cloudProxyURL = "https://api.conch-talk.com/api/web-search"

    private let authService: AuthServiceProtocol
    private let session: URLSession

    /// - Parameters:
    ///   - authService: 认证服务，用于获取 JWT token。
    ///   - session: URL 会话，默认使用 shared，测试时可注入 stub。
    init(authService: AuthServiceProtocol, session: URLSession = .shared) {
        self.authService = authService
        self.session = session
    }

    /// 搜索是只读操作，无副作用。
    func validateSafety(arguments: [String: Any]) -> SafetyLevel {
        .safe
    }

    func execute(arguments: [String: Any], sshClient: SSHClientProtocol) async throws -> ToolExecutionResult {
        // 参数校验
        guard let query = arguments["query"] as? String else {
            throw ToolError.missingParameter("query")
        }
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ToolError.invalidArguments("query must not be empty")
        }

        // 构建请求体
        var body: [String: Any] = ["query": query]
        if let country = arguments["country"] as? String { body["country"] = country }
        if let searchLang = arguments["search_lang"] as? String { body["search_lang"] = searchLang }
        if let freshness = arguments["freshness"] as? String { body["freshness"] = freshness }
        if let count = arguments["count"] as? Int { body["count"] = min(max(count, 1), 20) }

        // 构建 HTTP 请求
        let token = try await authService.validAccessToken()
        guard let proxyURL = URL(string: Self.cloudProxyURL) else {
            throw ToolError.executionFailed("Invalid cloud proxy URL")
        }
        var request = URLRequest(url: proxyURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        // 发送请求
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ToolError.executionFailed("Invalid HTTP response")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            return ToolExecutionResult(
                output: "Web search failed (HTTP \(httpResponse.statusCode)): \(errorBody)",
                isSuccess: false
            )
        }

        // 解析并格式化响应
        let output = try formatResponse(data)
        return ToolExecutionResult(output: output)
    }

    // MARK: - Response Formatting

    /// 将 Brave LLM Context API 响应格式化为 AI 可读的文本。
    private func formatResponse(_ data: Data) throws -> String {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let grounding = json["grounding"] as? [String: Any],
              let generic = grounding["generic"] as? [[String: Any]]
        else {
            throw ToolError.executionFailed("Invalid response format from search API")
        }

        let sources = json["sources"] as? [String: Any] ?? [:]
        var output = ""

        for item in generic {
            guard let url = item["url"] as? String,
                  let title = item["title"] as? String,
                  let snippets = item["snippets"] as? [String]
            else { continue }

            // 从 sources 获取元信息
            let sourceInfo = sources[url] as? [String: Any]
            let hostname = sourceInfo?["hostname"] as? String ?? URL(string: url)?.host ?? ""
            let age = (sourceInfo?["age"] as? [String])?.first

            // 格式化输出
            var header = "[Source: \(hostname)"
            if let age { header += " - \(age)" }
            header += "]"

            output += "\(header)\nTitle: \(title)\nURL: \(url)\n---\n"
            output += snippets.joined(separator: "\n\n")
            output += "\n\n"
        }

        if output.isEmpty {
            return "No search results found."
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
