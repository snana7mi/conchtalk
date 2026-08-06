/// 文件说明：WebSearchProviderClient，封装不同联网搜索服务的请求与响应差异。
import Foundation

/// WebSearchQuery：
/// 保存 WebSearchTool 校验后的通用查询参数，由各提供商适配器按能力映射。
nonisolated struct WebSearchQuery: Sendable {
    let text: String
    let country: String?
    let language: String?
    let freshness: String?
    let count: Int
}

/// WebSearchProviderClient：
/// 为单个搜索提供商创建认证请求，并把响应统一整理为模型可引用的文本。
nonisolated protocol WebSearchProviderClient: Sendable {
    var provider: WebSearchProvider { get }
    func makeRequest(query: WebSearchQuery, apiKey: String) throws -> URLRequest
    func formatResponse(_ data: Data) throws -> String
}

/// WebSearchProviderClientFactory：根据用户设置选择对应的内置适配器。
nonisolated enum WebSearchProviderClientFactory {
    static func make(for provider: WebSearchProvider) -> any WebSearchProviderClient {
        switch provider {
        case .brave: BraveSearchProviderClient()
        case .exa: ExaSearchProviderClient()
        case .anySearch: AnySearchProviderClient()
        case .tavily: TavilySearchProviderClient()
        }
    }
}

/// BraveSearchProviderClient：适配 Brave Web Search API。
nonisolated struct BraveSearchProviderClient: WebSearchProviderClient {
    let provider = WebSearchProvider.brave
    private static let endpoint = URL(string: "https://api.search.brave.com/res/v1/web/search")!

    func makeRequest(query: WebSearchQuery, apiKey: String) throws -> URLRequest {
        var components = URLComponents(url: Self.endpoint, resolvingAgainstBaseURL: false)!
        var queryItems = [
            URLQueryItem(name: "q", value: query.text),
            URLQueryItem(name: "count", value: String(query.count)),
            URLQueryItem(name: "result_filter", value: "web"),
            URLQueryItem(name: "text_decorations", value: "false"),
        ]
        for (name, value) in [
            ("country", query.country),
            ("search_lang", query.language),
            ("freshness", query.freshness),
        ] where value != nil {
            queryItems.append(URLQueryItem(name: name, value: value))
        }
        components.queryItems = queryItems
        guard let url = components.url else {
            throw ToolError.executionFailed("Unable to construct Brave Search URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(apiKey, forHTTPHeaderField: "X-Subscription-Token")
        return request
    }

    func formatResponse(_ data: Data) throws -> String {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let web = root["web"] as? [String: Any]
        else {
            throw ToolError.executionFailed("Invalid response format from Brave")
        }
        let results = web["results"] as? [[String: Any]] ?? []
        let entries = results.compactMap { result -> WebSearchResultEntry? in
            guard let title = result["title"] as? String,
                  let url = result["url"] as? String
            else { return nil }
            return WebSearchResultEntry(
                title: title,
                url: url,
                published: result["age"] as? String,
                snippets: [result["description"] as? String]
                    + (result["extra_snippets"] as? [String] ?? []).map(Optional.some)
            )
        }
        return WebSearchResponseFormatter.format(entries)
    }
}

/// ExaSearchProviderClient：适配 Exa Search API。
nonisolated struct ExaSearchProviderClient: WebSearchProviderClient {
    let provider = WebSearchProvider.exa
    private static let endpoint = URL(string: "https://api.exa.ai/search")!

    func makeRequest(query: WebSearchQuery, apiKey: String) throws -> URLRequest {
        var body: [String: Any] = [
            "query": query.text,
            "numResults": query.count,
            "type": "auto",
            "contents": ["highlights": true],
        ]
        if let country = query.country {
            body["userLocation"] = country.uppercased()
        }

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    func formatResponse(_ data: Data) throws -> String {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = root["results"] as? [[String: Any]]
        else {
            throw ToolError.executionFailed("Invalid response format from Exa")
        }
        let entries = results.compactMap { result -> WebSearchResultEntry? in
            guard let title = result["title"] as? String,
                  let url = result["url"] as? String
            else { return nil }
            var snippets = result["highlights"] as? [String] ?? []
            if snippets.isEmpty, let summary = result["summary"] as? String {
                snippets.append(summary)
            }
            if snippets.isEmpty, let text = result["text"] as? String {
                snippets.append(String(text.prefix(2_000)))
            }
            return WebSearchResultEntry(
                title: title,
                url: url,
                published: result["publishedDate"] as? String,
                snippets: snippets
            )
        }
        return WebSearchResponseFormatter.format(entries)
    }
}

/// AnySearchProviderClient：适配 AnySearch 统一搜索 API。
nonisolated struct AnySearchProviderClient: WebSearchProviderClient {
    let provider = WebSearchProvider.anySearch
    private static let endpoint = URL(string: "https://api.anysearch.com/v1/search")!

    func makeRequest(query: WebSearchQuery, apiKey: String) throws -> URLRequest {
        var body: [String: Any] = [
            "query": query.text,
            "max_results": query.count,
            "format": "json",
        ]
        if let country = query.country {
            body["zone"] = country.uppercased() == "CN" ? "cn" : "intl"
        }
        if let language = query.language {
            body["language"] = language
        }

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    func formatResponse(_ data: Data) throws -> String {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = root["data"] as? [String: Any],
              let results = payload["results"] as? [[String: Any]]
        else {
            throw ToolError.executionFailed("Invalid response format from AnySearch")
        }
        let entries = results.compactMap { result -> WebSearchResultEntry? in
            guard let title = result["title"] as? String,
                  let url = result["url"] as? String
            else { return nil }
            var snippets = [result["snippet"] as? String]
            if let content = result["content"] as? String, !content.isEmpty {
                snippets.append(String(content.prefix(2_000)))
            }
            return WebSearchResultEntry(
                title: title,
                url: url,
                published: nil,
                snippets: snippets
            )
        }
        return WebSearchResponseFormatter.format(entries)
    }
}

/// TavilySearchProviderClient：适配面向 AI Agent 的 Tavily Search API。
nonisolated struct TavilySearchProviderClient: WebSearchProviderClient {
    let provider = WebSearchProvider.tavily
    private static let endpoint = URL(string: "https://api.tavily.com/search")!

    func makeRequest(query: WebSearchQuery, apiKey: String) throws -> URLRequest {
        var body: [String: Any] = [
            "query": query.text,
            "max_results": query.count,
            "search_depth": "basic",
            "include_answer": false,
            "include_raw_content": false,
        ]
        if let country = Self.countryName(for: query.country) {
            body["country"] = country
        }
        for (key, value) in Self.freshnessParameters(for: query.freshness) {
            body[key] = value
        }

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    func formatResponse(_ data: Data) throws -> String {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = root["results"] as? [[String: Any]]
        else {
            throw ToolError.executionFailed("Invalid response format from Tavily")
        }
        let entries = results.compactMap { result -> WebSearchResultEntry? in
            guard let title = result["title"] as? String,
                  let url = result["url"] as? String
            else { return nil }
            return WebSearchResultEntry(
                title: title,
                url: url,
                published: (result["published_date"] ?? result["publishedDate"]) as? String,
                snippets: [result["content"] as? String]
            )
        }
        return WebSearchResponseFormatter.format(entries)
    }

    /// Tavily 的 country 参数使用英文国家名，而通用工具参数使用 ISO 两字母代码。
    private static func countryName(for regionCode: String?) -> String? {
        guard let regionCode else { return nil }
        return Locale(identifier: "en_US")
            .localizedString(forRegionCode: regionCode.uppercased())?
            .lowercased()
    }

    /// 将通用 freshness 参数映射为 Tavily 的时间范围或起止日期。
    private static func freshnessParameters(for freshness: String?) -> [String: String] {
        guard let freshness else { return [:] }
        switch freshness {
        case "pd": return ["time_range": "day"]
        case "pw": return ["time_range": "week"]
        case "pm": return ["time_range": "month"]
        case "py": return ["time_range": "year"]
        default:
            let dates = freshness.components(separatedBy: "to")
            guard dates.count == 2,
                  dates.allSatisfy({ $0.count == 10 })
            else { return [:] }
            return ["start_date": dates[0], "end_date": dates[1]]
        }
    }
}

/// WebSearchResultEntry：提供商无关的单条搜索结果。
private nonisolated struct WebSearchResultEntry: Sendable {
    let title: String
    let url: String
    let published: String?
    let snippets: [String?]
}

/// WebSearchResponseFormatter：将搜索结果统一为模型易于引用的来源列表。
private nonisolated enum WebSearchResponseFormatter {
    static func format(_ entries: [WebSearchResultEntry]) -> String {
        let output = entries.enumerated().map { index, entry in
            var lines = ["## \(index + 1). \(entry.title)", "URL: \(entry.url)"]
            if let published = entry.published, !published.isEmpty {
                lines.append("Published: \(published)")
            }
            lines.append(contentsOf: entry.snippets.compactMap { snippet in
                guard let snippet, !snippet.isEmpty else { return nil }
                return snippet
            })
            return lines.joined(separator: "\n")
        }
        return output.isEmpty
            ? "No web search results found."
            : output.joined(separator: "\n\n")
    }
}
