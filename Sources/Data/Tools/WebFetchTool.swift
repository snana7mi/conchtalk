/// 文件说明：WebFetchTool，通过远端服务器网络抓取 URL 内容并转换为指定格式。
/// 借鉴 OpenCode webfetch 设计，支持 text/markdown/html 三种输出、Cloudflare 重试与响应大小限制。
import Foundation

/// WebFetchTool：
/// 通用网页内容抓取工具，通过远端服务器的 curl 获取 URL 内容。
/// 支持多种输出格式，自动检测服务器上可用的转换工具（pandoc > w3m > lynx > sed）。
nonisolated struct WebFetchTool: ToolProtocol, @unchecked Sendable {
    let name = "web_fetch"
    let description = """
        Fetch content from a URL. Use this instead of curl via execute_ssh_command — \
        it handles HTTP errors, retries, and HTML-to-markdown conversion automatically. \
        Prefer format 'markdown' for docs/web pages, 'text' for quick extraction. \
        Always fetch URLs before referencing or summarizing them.
        """

    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "url": [
                "type": "string",
                "description": "The URL to fetch content from (must start with http:// or https://)",
            ] as [String: String],
            "format": [
                "type": "string",
                "enum": ["text", "markdown", "html"],
                "description": "Output format: 'text' strips all HTML tags, 'markdown' converts HTML to markdown (requires pandoc, falls back to text), 'html' returns raw HTML. Defaults to 'markdown'.",
            ] as [String: Any],
            "timeout": [
                "type": "integer",
                "description": "Request timeout in seconds (1-120). Defaults to 30.",
            ] as [String: String],
            "explanation": [
                "type": "string",
                "description": "Brief explanation of why you need to fetch this URL",
            ] as [String: String],
        ] as [String: Any],
        "required": ["url", "explanation"],
    ]

    private static let maxResponseSize = 5 * 1024 * 1024 // 5MB
    private static let maxOutputChars = 100_000

    var supportsStreaming: Bool { true }

    /// 纯读取操作（抓取网页内容），无破坏性副作用，自动执行。
    func validateSafety(arguments: [String: Any]) -> SafetyLevel {
        .safe
    }

    func execute(arguments: [String: Any], sshClient: SSHClientProtocol) async throws -> ToolExecutionResult {
        guard let stream = try await executeStreaming(arguments: arguments, sshClient: sshClient) else {
            throw ToolError.invalidArguments("Failed to create stream")
        }
        var result = ""
        for try await chunk in stream {
            result = chunk
        }
        return ToolExecutionResult(output: result)
    }

    func executeStreaming(arguments: [String: Any], sshClient: SSHClientProtocol) async throws -> AsyncThrowingStream<String, Error>? {
        guard let url = arguments["url"] as? String else {
            throw ToolError.missingParameter("url")
        }
        guard url.hasPrefix("http://") || url.hasPrefix("https://") else {
            throw ToolError.invalidArguments("URL must start with http:// or https://")
        }

        // SSRF 防护：拒绝非公网目标（IMDS / 回环 / 私网 / 链路本地 / CGNAT / IPv6 回环与 ULA）。
        // fail-closed：host 缺失或无法解析也一律拒绝；拦截发生在任何远端命令执行之前。
        // 域名场景为尽力而为：客户端解析与远端 curl 的 DNS 视图可能不一致，
        // IP 锁定（curl --resolve）见后续 SSRF 加固计划。
        guard let host = URL(string: url)?.host(percentEncoded: false), !host.isEmpty else {
            throw ToolError.invalidArguments("URL has no resolvable host")
        }
        // classify 对域名走无超时的同步阻塞 getaddrinfo，而本方法会继承调用方执行上下文
        //（NonisolatedNonsendingByDefault），源头是 MainActor——DNS 慢/超时会冻结 UI，
        // 放后台 detached 执行（与 IPGeoService.lookupCountryCode 调用方的既有惯例一致）。
        let hostClass = await Task.detached(priority: .utility) {
            PrivateNetworkGuard.classify(host: host)
        }.value
        guard hostClass == .publicHost else {
            throw ToolError.invalidArguments(
                "Refusing to fetch non-public address (loopback/private/link-local/metadata)."
            )
        }

        let format = (arguments["format"] as? String) ?? "markdown"
        guard ["text", "markdown", "html"].contains(format) else {
            throw ToolError.invalidArguments("format must be one of: text, markdown, html")
        }

        let timeout = min(max((arguments["timeout"] as? Int) ?? 30, 1), 120)

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    func progress(_ step: String) {
                        continuation.yield("[progress] \(step)")
                    }

                    let safeURL = shellEscape(url)

                    // ── 1. 检测服务器上可用的转换工具 ──
                    progress("Detecting conversion tools...")
                    let converter = try await detectConverter(sshClient: sshClient)
                    try Task.checkCancellation()

                    // ── 2. 抓取页面到临时文件 + 获取元信息 ──
                    progress("Fetching \(url)...")
                    let (tmpFile, httpCode, contentType) = try await fetchToTempFile(
                        url: safeURL, timeout: timeout, sshClient: sshClient
                    )
                    try Task.checkCancellation()

                    // ── 3. Cloudflare 403 重试（换 User-Agent） ──
                    var finalCode = httpCode
                    if httpCode == 403 {
                        progress("Retrying with alternative User-Agent...")
                        let retryResult = try await fetchToTempFile(
                            url: safeURL, timeout: timeout,
                            userAgent: "conchtalk", tmpFilePath: tmpFile,
                            sshClient: sshClient
                        )
                        finalCode = retryResult.httpCode
                    }
                    try Task.checkCancellation()

                    // ── 4. HTTP 错误处理 ──
                    if finalCode >= 400 || finalCode == 0 {
                        try await cleanupTempFile(tmpFile, sshClient: sshClient)
                        let errorJSON = formatError(
                            url: url, httpCode: finalCode,
                            message: finalCode == 0
                                ? "Request failed (server may lack internet access or curl is not installed)"
                                : "Request failed with HTTP \(finalCode)"
                        )
                        continuation.yield(errorJSON)
                        continuation.finish()
                        return
                    }

                    // ── 5. 判断是否为 HTML 并按格式转换 ──
                    let isHTML = contentType.contains("text/html")
                        || contentType.contains("application/xhtml")

                    progress("Processing content...")
                    let content: String
                    switch format {
                    case "html":
                        content = try await readTempFile(tmpFile, sshClient: sshClient)

                    case "markdown" where isHTML:
                        progress("Converting HTML to markdown...")
                        content = try await convertFromTempFile(
                            tmpFile, to: .markdown, using: converter, sshClient: sshClient
                        )

                    case "text" where isHTML:
                        progress("Extracting text from HTML...")
                        content = try await convertFromTempFile(
                            tmpFile, to: .text, using: converter, sshClient: sshClient
                        )

                    default:
                        // 非 HTML 内容（JSON / 纯文本等），直接返回
                        content = try await readTempFile(tmpFile, sshClient: sshClient)
                    }
                    try Task.checkCancellation()

                    // ── 6. 清理临时文件 ──
                    try await cleanupTempFile(tmpFile, sshClient: sshClient)

                    // ── 7. 截断过长输出 ──
                    let truncated = content.count > Self.maxOutputChars
                    let finalContent = truncated
                        ? String(content.prefix(Self.maxOutputChars)) + "\n\n[Content truncated at \(Self.maxOutputChars) characters]"
                        : content

                    // ── 8. 组装结果 ──
                    let header = "URL: \(url)\nContent-Type: \(contentType)\nFormat: \(format)\(truncated ? "\nTruncated: true" : "")\n---\n"
                    continuation.yield(header + finalContent)
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Fetch

    /// 将 URL 内容抓取到远端临时文件，返回文件路径、HTTP 状态码和 Content-Type。
    private func fetchToTempFile(
        url: String,
        timeout: Int,
        userAgent: String = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36",
        tmpFilePath: String? = nil,
        sshClient: SSHClientProtocol
    ) async throws -> (tmpFile: String, httpCode: Int, contentType: String) {
        // 使用已有路径或通过 mktemp 创建
        let mkTmpCmd = tmpFilePath.map { "echo \(shellEscape($0))" }
            ?? "mktemp /tmp/conchtalk_wf.XXXXXX"

        let raw = try await sshClient.execute(command: """
            _tmpf=$(\(mkTmpCmd)) && \
            _meta=$(curl -sL --connect-timeout 10 --max-time \(timeout) \
                --max-filesize \(Self.maxResponseSize) \
                -H 'User-Agent: \(userAgent)' \
                -H 'Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8' \
                -H 'Accept-Language: en-US,en;q=0.9' \
                -o "$_tmpf" \
                -w '%{http_code}\\n%{content_type}' \
                \(url) 2>/dev/null) && \
            echo "$_tmpf" && echo "$_meta"
            """)

        let lines = raw.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        let file = lines.first ?? "/tmp/conchtalk_wf_err"
        let code = lines.count > 1 ? (Int(lines[1]) ?? 0) : 0
        let ctype = lines.count > 2 ? lines[2] : ""

        return (file, code, ctype)
    }

    // MARK: - Content Conversion

    private enum OutputFormat { case text, markdown }

    private enum Converter {
        case pandoc
        case w3m
        case lynx
        case sedFallback
    }

    /// 按优先级检测远端可用的 HTML 转换工具。
    private func detectConverter(sshClient: SSHClientProtocol) async throws -> Converter {
        let check = try await sshClient.execute(command: """
            (command -v pandoc >/dev/null 2>&1 && echo 'pandoc') || \
            (command -v w3m >/dev/null 2>&1 && echo 'w3m') || \
            (command -v lynx >/dev/null 2>&1 && echo 'lynx') || \
            echo 'none'
            """)
        let result = check.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.contains("pandoc") { return .pandoc }
        if result.contains("w3m") { return .w3m }
        if result.contains("lynx") { return .lynx }
        return .sedFallback
    }

    /// 从临时文件读取 HTML 并转换为指定格式。
    private func convertFromTempFile(
        _ tmpFile: String,
        to format: OutputFormat,
        using converter: Converter,
        sshClient: SSHClientProtocol
    ) async throws -> String {
        let pipeline: String
        switch (converter, format) {
        case (.pandoc, .markdown):
            pipeline = "pandoc -f html -t markdown --wrap=none 2>/dev/null"
        case (.pandoc, .text):
            pipeline = "pandoc -f html -t plain --wrap=none 2>/dev/null"
        case (.w3m, _):
            pipeline = "w3m -dump -T text/html 2>/dev/null"
        case (.lynx, _):
            pipeline = "lynx -dump -stdin -nolist -width=200 2>/dev/null"
        case (.sedFallback, _):
            // sed 降级：去标签 + 合并空行 + 解码常见 HTML 实体
            pipeline = "sed 's/<script[^>]*>.*<\\/script>//g; s/<style[^>]*>.*<\\/style>//g; s/<[^>]*>//g' | sed '/^$/N;/^\\n$/d' | sed 's/&amp;/\\&/g; s/&lt;/</g; s/&gt;/>/g; s/&quot;/\"/g; s/&#39;/\\x27/g'"
        }

        let safeTmp = shellEscape(tmpFile)
        let result = try await sshClient.execute(command: "cat \(safeTmp) | \(pipeline) | head -4000")
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 直接读取临时文件内容。
    private func readTempFile(_ tmpFile: String, sshClient: SSHClientProtocol) async throws -> String {
        let safeTmp = shellEscape(tmpFile)
        let result = try await sshClient.execute(command: "head -c \(Self.maxOutputChars) \(safeTmp)")
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 清理临时文件。
    private func cleanupTempFile(_ tmpFile: String, sshClient: SSHClientProtocol) async throws {
        let safeTmp = shellEscape(tmpFile)
        _ = try? await sshClient.execute(command: "rm -f \(safeTmp)")
    }

    // MARK: - Error Formatting

    private func formatError(url: String, httpCode: Int, message: String) -> String {
        let result: [String: Any] = [
            "url": url,
            "error": true,
            "http_code": httpCode,
            "message": message,
        ]
        guard let json = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]),
              let str = String(data: json, encoding: .utf8)
        else { return "{\"error\": true, \"message\": \"\(message)\"}" }
        return str
    }
}
