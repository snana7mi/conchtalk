/// 文件说明：AnthropicThinkingTests，验证 Anthropic 思考块回放、stop_reason 截断处理、max_tokens 与思考配置。
import Testing
@testable import ConchTalk
import Foundation

// MARK: - 模型能力推断

@Suite("AnthropicModelCapabilities")
struct AnthropicModelCapabilitiesTests {

    @Test("解析新旧两种模型命名")
    func parsesModelNames() {
        #expect(AnthropicModelCapabilities.version(of: "claude-opus-4-6") == .init(family: "opus", major: 4, minor: 6))
        #expect(AnthropicModelCapabilities.version(of: "claude-sonnet-4-5-20250929") == .init(family: "sonnet", major: 4, minor: 5))
        // 日期后缀不能被当作 minor
        #expect(AnthropicModelCapabilities.version(of: "claude-sonnet-4-20250514") == .init(family: "sonnet", major: 4, minor: 0))
        #expect(AnthropicModelCapabilities.version(of: "us.anthropic.claude-opus-4-7-v1:0") == .init(family: "opus", major: 4, minor: 7))
        #expect(AnthropicModelCapabilities.version(of: "claude-3-7-sonnet-20250219") == .init(family: "sonnet", major: 3, minor: 7))
        #expect(AnthropicModelCapabilities.version(of: "claude-haiku-5-5") == .init(family: "haiku", major: 5, minor: 5))
        #expect(AnthropicModelCapabilities.version(of: "claude-mythos-preview") == .init(family: "mythos", major: nil, minor: 0))
        #expect(AnthropicModelCapabilities.version(of: "deepseek-chat") == nil)
    }

    @Test("思考模式：4.6+ / 5.x 用 adaptive，4.5 及以前与未知模型用 manual")
    func thinkingModes() {
        #expect(AnthropicModelCapabilities.thinkingMode(for: "claude-opus-4-6") == .adaptive)
        #expect(AnthropicModelCapabilities.thinkingMode(for: "claude-sonnet-5") == .adaptive)
        #expect(AnthropicModelCapabilities.thinkingMode(for: "claude-fable-5-1") == .adaptive)
        #expect(AnthropicModelCapabilities.thinkingMode(for: "claude-sonnet-4-5-20250929") == .manual)
        #expect(AnthropicModelCapabilities.thinkingMode(for: "claude-3-7-sonnet-20250219") == .manual)
        #expect(AnthropicModelCapabilities.thinkingMode(for: "kimi-k2") == .manual)
    }

    @Test("自动 max_tokens 按模型分档")
    func defaultMaxTokens() {
        #expect(AnthropicModelCapabilities.defaultMaxOutputTokens(for: "claude-opus-4-6") == 32_000)
        #expect(AnthropicModelCapabilities.defaultMaxOutputTokens(for: "claude-haiku-5-5") == 32_000)
        #expect(AnthropicModelCapabilities.defaultMaxOutputTokens(for: "claude-sonnet-4-5-20250929") == 16_000)
        #expect(AnthropicModelCapabilities.defaultMaxOutputTokens(for: "claude-3-7-sonnet-20250219") == 16_000)
        #expect(AnthropicModelCapabilities.defaultMaxOutputTokens(for: "claude-3-5-sonnet-20241022") == 8192)
        #expect(AnthropicModelCapabilities.defaultMaxOutputTokens(for: "claude-3-haiku-20240307") == 4096)
        #expect(AnthropicModelCapabilities.defaultMaxOutputTokens(for: "glm-4.6") == 8192)
    }

    @Test("Opus 4.7+ / 5.x 拒绝非默认 temperature")
    func samplingRestrictions() {
        #expect(AnthropicModelCapabilities.rejectsSamplingParameters("claude-opus-4-7"))
        #expect(AnthropicModelCapabilities.rejectsSamplingParameters("claude-sonnet-5-5"))
        #expect(!AnthropicModelCapabilities.rejectsSamplingParameters("claude-sonnet-4-6"))
        #expect(!AnthropicModelCapabilities.rejectsSamplingParameters("claude-3-5-sonnet-20241022"))
        #expect(!AnthropicModelCapabilities.rejectsSamplingParameters("deepseek-chat"))
    }

    @Test("manual 预算 ≥1024 且 < max_tokens")
    func manualBudget() {
        #expect(AnthropicModelCapabilities.manualThinkingBudget(level: .high, maxTokens: 32_000) == 16_384)
        #expect(AnthropicModelCapabilities.manualThinkingBudget(level: .high, maxTokens: 8192) == 7168)
        #expect(AnthropicModelCapabilities.manualThinkingBudget(level: .low, maxTokens: 8192) == 2048)
        #expect(AnthropicModelCapabilities.manualThinkingBudget(level: .low, maxTokens: 1500) == nil)
        #expect(AnthropicModelCapabilities.manualThinkingBudget(level: .modelDefault, maxTokens: 32_000) == nil)
    }

    @Test("400 错误信息映射到应切换的思考模式")
    func fallbackParsing() {
        #expect(AnthropicModelCapabilities.thinkingModeFallback(from: "adaptive thinking is not supported on this model") == .manual)
        #expect(AnthropicModelCapabilities.thinkingModeFallback(
            from: #""thinking.type.enabled" is not supported for this model. Use "thinking.type.adaptive" and "output_config.effort" to control thinking behavior."#
        ) == .adaptive)
        #expect(AnthropicModelCapabilities.thinkingModeFallback(from: "rate limit exceeded") == nil)
    }
}

// MARK: - 请求体

@Suite("AnthropicFormatStrategy thinking / max_tokens")
struct AnthropicRequestBodyTests {
    private let messages: [[String: Any]] = [["role": "user", "content": "Hi"]]

    private func body(_ strategy: AnthropicFormatStrategy, model: String) throws -> [String: Any] {
        let data = try strategy.buildStreamingRequestBody(messages: messages, model: model, toolDefinitions: [])
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("默认按模型自动 max_tokens，且不发送 thinking")
    func autoMaxTokensNoThinking() throws {
        let json = try body(AnthropicFormatStrategy(), model: "claude-opus-4-6")
        #expect(json["max_tokens"] as? Int == 32_000)
        #expect(json["thinking"] == nil)
        #expect(json["output_config"] == nil)
    }

    @Test("用户指定 max_tokens 优先")
    func userMaxTokens() throws {
        let json = try body(AnthropicFormatStrategy(maxOutputTokens: 12_000), model: "claude-opus-4-6")
        #expect(json["max_tokens"] as? Int == 12_000)
    }

    @Test("adaptive 模型：thinking adaptive + output_config.effort")
    func adaptiveThinking() throws {
        let json = try body(AnthropicFormatStrategy(thinkingLevel: .medium), model: "claude-sonnet-4-6")
        #expect((json["thinking"] as? [String: Any])?["type"] as? String == "adaptive")
        #expect((json["output_config"] as? [String: Any])?["effort"] as? String == "medium")
    }

    @Test("manual 模型：thinking enabled + budget_tokens < max_tokens")
    func manualThinking() throws {
        let json = try body(AnthropicFormatStrategy(thinkingLevel: .high), model: "claude-sonnet-4-5-20250929")
        let thinking = try #require(json["thinking"] as? [String: Any])
        #expect(thinking["type"] as? String == "enabled")
        #expect(thinking["budget_tokens"] as? Int == 14_976)  // 16000 - 1024
        #expect(json["output_config"] == nil)
    }

    @Test("自愈覆盖思考模式")
    func overrideMode() throws {
        let strategy = AnthropicFormatStrategy(thinkingLevel: .low).withThinkingMode(.manual)
        let json = try body(strategy, model: "claude-opus-4-6")
        #expect((json["thinking"] as? [String: Any])?["type"] as? String == "enabled")
    }

    @Test("辅助请求：新模型省略 temperature 并降低 effort，旧模型保留 temperature")
    func nonStreamingSampling() throws {
        let strategy = AnthropicFormatStrategy()
        let modern = try #require(try JSONSerialization.jsonObject(with: strategy.buildNonStreamingRequestBody(
            messages: messages, model: "claude-opus-4-7", maxTokens: 300, temperature: 0.3, reasoningEffort: "none"
        )) as? [String: Any])
        #expect(modern["temperature"] == nil)
        #expect((modern["output_config"] as? [String: Any])?["effort"] as? String == "low")

        let legacy = try #require(try JSONSerialization.jsonObject(with: strategy.buildNonStreamingRequestBody(
            messages: messages, model: "claude-3-5-sonnet-20241022", maxTokens: 300, temperature: 0.3, reasoningEffort: "none"
        )) as? [String: Any])
        #expect(legacy["temperature"] as? Double == 0.3)
        #expect(legacy["output_config"] == nil)
    }

    @Test("非流式解析拼接 text 块并跳过 thinking 块")
    func nonStreamingSkipsThinking() throws {
        let response: [String: Any] = ["content": [
            ["type": "thinking", "thinking": "", "signature": "sig"],
            ["type": "text", "text": "Title "],
            ["type": "text", "text": "here"],
        ]]
        let data = try JSONSerialization.data(withJSONObject: response)
        #expect(try AnthropicFormatStrategy().parseNonStreamingContent(from: data) == "Title here")
    }

    @Test("原样回放 thinking / redacted_thinking 块（含 signature），优先于 reasoning_content")
    func replaysVerbatimThinkingBlocks() throws {
        let history: [[String: Any]] = [
            ["role": "user", "content": "check disk"],
            [
                "role": "assistant",
                "content": NSNull(),
                "reasoning_content": "plain text that must not be used",
                MessageBuilder.anthropicThinkingBlocksKey: [
                    ["type": "thinking", "thinking": "let me look", "signature": "SIG123"],
                    ["type": "redacted_thinking", "data": "ENCRYPTED"],
                ],
                "tool_calls": [[
                    "id": "toolu_1", "type": "function",
                    "function": ["name": "execute_ssh_command", "arguments": #"{"command":"df -h"}"#],
                ]],
            ],
            ["role": "tool", "tool_call_id": "toolu_1", "content": "ok"],
        ]
        let data = try AnthropicFormatStrategy().buildStreamingRequestBody(messages: history, model: "claude-opus-4-6", toolDefinitions: [])
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let converted = try #require(json["messages"] as? [[String: Any]])
        let assistant = try #require(converted.first { $0["role"] as? String == "assistant" })
        let blocks = try #require(assistant["content"] as? [[String: Any]])
        #expect(blocks.count == 3)
        #expect(blocks[0]["type"] as? String == "thinking")
        #expect(blocks[0]["signature"] as? String == "SIG123")
        #expect(blocks[1]["type"] as? String == "redacted_thinking")
        #expect(blocks[1]["data"] as? String == "ENCRYPTED")
        #expect(blocks[2]["type"] as? String == "tool_use")
        let raw = String(data: data, encoding: .utf8) ?? ""
        #expect(!raw.contains("plain text that must not be used"))
        #expect(!raw.contains(MessageBuilder.anthropicThinkingBlocksKey))
    }
}

// MARK: - SSE 解析

@Suite("AnthropicStreamParser")
struct AnthropicStreamParserTests {

    private func run(_ events: [(String, [String: Any])], finishAtEnd: Bool = false, maxTokens: Int? = nil) -> [StreamingDelta] {
        var parser = AnthropicStreamParser(maxTokens: maxTokens)
        var deltas: [StreamingDelta] = []
        for (event, json) in events {
            deltas += parser.handle(event: event, json: json)
        }
        if finishAtEnd { deltas += parser.finish() }
        return deltas
    }

    private func toolCalls(_ deltas: [StreamingDelta]) -> [ToolCall] {
        deltas.compactMap { if case .toolCall(let call) = $0 { return call } else { return nil } }
    }

    private func contents(_ deltas: [StreamingDelta]) -> String {
        deltas.compactMap { if case .content(let text) = $0 { return text } else { return nil } }.joined()
    }

    @Test("收集 thinking + signature + redacted 块，挂到首个工具调用并带 responseID")
    func collectsThinkingBlocks() throws {
        let deltas = run([
            ("message_start", ["message": ["id": "msg_1", "usage": ["input_tokens": 10]]]),
            ("content_block_start", ["index": 0, "content_block": ["type": "thinking", "thinking": ""]]),
            ("content_block_delta", ["index": 0, "delta": ["type": "thinking_delta", "thinking": "plan "]]),
            ("content_block_delta", ["index": 0, "delta": ["type": "thinking_delta", "thinking": "steps"]]),
            ("content_block_delta", ["index": 0, "delta": ["type": "signature_delta", "signature": "SIG"]]),
            ("content_block_stop", ["index": 0]),
            ("content_block_start", ["index": 1, "content_block": ["type": "redacted_thinking", "data": "ENC"]]),
            ("content_block_stop", ["index": 1]),
            ("content_block_start", ["index": 2, "content_block": ["type": "tool_use", "id": "toolu_a", "name": "read_file"]]),
            ("content_block_delta", ["index": 2, "delta": ["type": "input_json_delta", "partial_json": #"{"path":"/etc/"#]]),
            ("content_block_delta", ["index": 2, "delta": ["type": "input_json_delta", "partial_json": #"hosts"}"#]]),
            ("content_block_stop", ["index": 2]),
            ("content_block_start", ["index": 3, "content_block": ["type": "tool_use", "id": "toolu_b", "name": "get_time"]]),
            ("content_block_stop", ["index": 3]),
            ("message_delta", ["delta": ["stop_reason": "tool_use"], "usage": ["output_tokens": 42]]),
            ("message_stop", [:]),
        ])

        let calls = toolCalls(deltas)
        #expect(calls.count == 2)
        #expect(calls[0].responseID == "msg_1")
        #expect(calls[1].responseID == "msg_1")
        #expect(calls[0].thinkingBlocks == [.thinking("plan steps", signature: "SIG"), .redacted(data: "ENC")])
        #expect(calls[1].thinkingBlocks == nil)
        #expect(!calls[0].isTruncated)
        // 无参数工具得到合法空对象，而不是空 Data（此前会触发参数解码错误）
        #expect(try calls[1].decodedArguments().isEmpty)
        if case .done = deltas.last {} else { Issue.record("最后一个事件应为 .done") }
    }

    @Test("stop_reason=max_tokens 截断的工具调用被标记，不产生解码错误")
    func marksTruncatedToolCall() {
        let deltas = run([
            ("message_start", ["message": ["id": "msg_2"]]),
            ("content_block_start", ["index": 0, "content_block": ["type": "tool_use", "id": "toolu_w", "name": "write_file"]]),
            ("content_block_delta", ["index": 0, "delta": ["type": "input_json_delta", "partial_json": #"{"path":"/tmp/a","content":"aaaa"#]]),
            ("content_block_stop", ["index": 0]),
            ("message_delta", ["delta": ["stop_reason": "max_tokens"]]),
            ("message_stop", [:]),
        ])
        let calls = toolCalls(deltas)
        #expect(calls.count == 1)
        #expect(calls[0].isTruncated)
        #expect(contents(deltas).isEmpty)
    }

    @Test("纯文本被 max_tokens 截断时追加提示")
    func textTruncationNotice() {
        let deltas = run([
            ("content_block_start", ["index": 0, "content_block": ["type": "text", "text": ""]]),
            ("content_block_delta", ["index": 0, "delta": ["type": "text_delta", "text": "Part one"]]),
            ("content_block_stop", ["index": 0]),
            ("message_delta", ["delta": ["stop_reason": "max_tokens"]]),
            ("message_stop", [:]),
        ], maxTokens: 4096)
        let text = contents(deltas)
        #expect(text.hasPrefix("Part one\n\n[Reply cut off"))
        #expect(text.contains("4096"))
    }

    @Test("流意外结束（无 message_stop）时仍产出缓冲的工具调用并标记截断")
    func unexpectedEnd() {
        let deltas = run([
            ("content_block_start", ["index": 0, "content_block": ["type": "tool_use", "id": "toolu_x", "name": "write_file"]]),
            ("content_block_delta", ["index": 0, "delta": ["type": "input_json_delta", "partial_json": #"{"path":"#]]),
        ], finishAtEnd: true)
        let calls = toolCalls(deltas)
        #expect(calls.count == 1)
        #expect(calls[0].isTruncated)
    }

    @Test("error 事件结束解析")
    func errorEvent() {
        var parser = AnthropicStreamParser()
        let deltas = parser.handle(event: "error", json: ["error": ["message": "Overloaded"]])
        #expect(parser.isFinished)
        guard case .error(let error) = deltas.first,
              case AIServiceError.apiError(_, let message)? = error as? AIServiceError else {
            Issue.record("应产出 apiError")
            return
        }
        #expect(message == "Overloaded")
        #expect(parser.finish().isEmpty)
    }
}

// MARK: - OpenAI 兼容格式

@Suite("OpenAIFormatStrategy truncation / private keys")
struct OpenAITruncationTests {

    @Test("finish_reason=length 时不完整参数标记截断，完整参数不标记")
    func finalizeToolCalls() {
        let calls = OpenAIFormatStrategy.finalizeToolCalls([
            (id: "c1", name: "read_file", args: #"{"path":"/a"}"#),
            (id: "c2", name: "write_file", args: #"{"path":"/b","content":"xx"#),
            (id: "c3", name: "get_time", args: ""),
            (id: nil, name: "broken", args: "{}"),
        ], finishReason: "length")
        #expect(calls.count == 3)
        #expect(!calls[0].isTruncated)
        #expect(calls[1].isTruncated)
        #expect(!calls[2].isTruncated)
        #expect(String(data: calls[2].argumentsJSON, encoding: .utf8) == "{}")
    }

    @Test("请求体剔除 _ 前缀私有键，并按设置发送 reasoning_effort")
    func stripsPrivateKeys() throws {
        let messages: [[String: Any]] = [[
            "role": "assistant", "content": NSNull(),
            MessageBuilder.anthropicThinkingBlocksKey: [["type": "thinking", "thinking": "x", "signature": "s"]],
        ]]
        let data = try OpenAIFormatStrategy(reasoningEffort: "high").buildStreamingRequestBody(
            messages: messages, model: "gpt-test", toolDefinitions: []
        )
        let raw = String(data: data, encoding: .utf8) ?? ""
        #expect(!raw.contains(MessageBuilder.anthropicThinkingBlocksKey))
        #expect(raw.contains(#""reasoning_effort":"high""#))

        let plain = try OpenAIFormatStrategy().buildStreamingRequestBody(messages: messages, model: "gpt-test", toolDefinitions: [])
        #expect(!(String(data: plain, encoding: .utf8) ?? "").contains("reasoning_effort"))
    }
}

// MARK: - 自愈策略

@Suite("UserAIService thinking fallback")
struct ThinkingFallbackTests {

    @Test("Anthropic：adaptive 被拒切 manual；模型默认档位不重试")
    func anthropicFallback() throws {
        let error = AIServiceError.apiError(statusCode: 400, message: "adaptive thinking is not supported on this model")
        let strategy = AnthropicFormatStrategy(thinkingLevel: .high)
        let fallback = try #require(UserAIService.thinkingFallbackStrategy(for: error, strategy: strategy) as? AnthropicFormatStrategy)
        #expect(fallback.thinkingModeOverride == .manual)
        // 同一模式不重复切换
        #expect(UserAIService.thinkingFallbackStrategy(for: error, strategy: fallback) == nil)
        #expect(UserAIService.thinkingFallbackStrategy(for: error, strategy: AnthropicFormatStrategy()) == nil)
    }

    @Test("OpenAI：reasoning_effort 被拒时去掉该参数；其他错误不重试")
    func openAIFallback() throws {
        let error = AIServiceError.apiError(statusCode: 400, message: "Unsupported parameter: 'reasoning_effort' is not supported with this model.")
        let fallback = try #require(UserAIService.thinkingFallbackStrategy(for: error, strategy: OpenAIFormatStrategy(reasoningEffort: "low")) as? OpenAIFormatStrategy)
        #expect(fallback.reasoningEffort == nil)
        let other = AIServiceError.apiError(statusCode: 400, message: "bad request")
        #expect(UserAIService.thinkingFallbackStrategy(for: other, strategy: OpenAIFormatStrategy(reasoningEffort: "low")) == nil)
        let serverError = AIServiceError.apiError(statusCode: 500, message: "reasoning_effort")
        #expect(UserAIService.thinkingFallbackStrategy(for: serverError, strategy: OpenAIFormatStrategy(reasoningEffort: "low")) == nil)
    }
}

// MARK: - ToolCall 持久化兼容与 MessageBuilder 合并

@Suite("ToolCall thinking metadata")
struct ToolCallThinkingMetadataTests {

    @Test("旧版 toolCallJSON（无新字段）仍可解码")
    func decodesLegacyJSON() throws {
        let legacy = try JSONEncoder().encode(TestFixtures.makeToolCall())
        let object = try #require(try JSONSerialization.jsonObject(with: legacy) as? [String: Any])
        #expect(object["thinkingBlocks"] == nil)
        let decoded = try JSONDecoder().decode(ToolCall.self, from: legacy)
        #expect(decoded.thinkingBlocks == nil)
        #expect(decoded.responseID == nil)
        #expect(!decoded.isTruncated)
    }

    @Test("thinking 块与 responseID 编解码往返")
    func roundTrips() throws {
        var call = TestFixtures.makeToolCall()
        call.responseID = "msg_9"
        call.thinkingBlocks = [.thinking("t", signature: "s"), .redacted(data: "d")]
        call.truncatedByMaxTokens = true
        let decoded = try JSONDecoder().decode(ToolCall.self, from: JSONEncoder().encode(call))
        #expect(decoded.responseID == "msg_9")
        #expect(decoded.thinkingBlocks == call.thinkingBlocks)
        #expect(decoded.isTruncated)
    }

    @Test("同一响应的连续工具调用合并为一条 assistant 消息并附带 thinking 块")
    func groupsSameResponse() throws {
        var first = TestFixtures.makeToolCall(id: "toolu_1", toolName: "read_file", arguments: ["path": "/a"])
        first.responseID = "msg_1"
        first.thinkingBlocks = [.thinking("why", signature: "SIG")]
        var second = TestFixtures.makeToolCall(id: "toolu_2", toolName: "read_file", arguments: ["path": "/b"])
        second.responseID = "msg_1"
        var third = TestFixtures.makeToolCall(id: "toolu_3", toolName: "read_file", arguments: ["path": "/c"])
        third.responseID = "msg_2"
        let history = [
            Message(role: .user, content: "read"),
            Message(role: .command, content: "a", toolCall: first, toolOutput: "A"),
            Message(role: .command, content: "b", toolCall: second, toolOutput: "B"),
            Message(role: .command, content: "c", toolCall: third, toolOutput: "C"),
        ]

        let built = MessageBuilder.build(from: history)
        #expect(built.map { $0["role"] as? String } == ["user", "assistant", "tool", "tool", "assistant", "tool"])
        let grouped = try #require(built[1]["tool_calls"] as? [[String: Any]])
        #expect(grouped.map { $0["id"] as? String } == ["toolu_1", "toolu_2"])
        let blocks = try #require(built[1][MessageBuilder.anthropicThinkingBlocksKey] as? [[String: Any]])
        #expect(blocks.first?["signature"] as? String == "SIG")
        #expect(built[4][MessageBuilder.anthropicThinkingBlocksKey] == nil)

        var options = MessageBuilderOptions()
        options.includeAnthropicThinkingBlocks = false
        let stripped = MessageBuilder.build(from: history, options: options)
        #expect(stripped[1][MessageBuilder.anthropicThinkingBlocksKey] == nil)
    }

    @Test("没有 responseID 的旧消息保持一调用一条 assistant")
    func legacyNotGrouped() {
        let history = [
            Message(role: .command, content: "a", toolCall: TestFixtures.makeToolCall(id: "c1"), toolOutput: "A"),
            Message(role: .command, content: "b", toolCall: TestFixtures.makeToolCall(id: "c2"), toolOutput: "B"),
        ]
        let built = MessageBuilder.build(from: history)
        #expect(built.map { $0["role"] as? String } == ["assistant", "tool", "assistant", "tool"])
    }
}
