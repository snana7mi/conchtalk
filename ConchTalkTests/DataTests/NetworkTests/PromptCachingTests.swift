/// 文件说明：PromptCachingTests，验证提示缓存相关的请求构建（顶层 cache_control、稳定键序）与 usage 解析。
import Testing
@testable import ConchTalk
import Foundation

@Suite("PromptCaching")
struct PromptCachingTests {

    private let messages: [[String: Any]] = [
        ["role": "system", "content": "You are a helpful assistant."],
        ["role": "user", "content": "List files"],
        [
            "role": "assistant",
            "content": "",
            "tool_calls": [[
                "id": "call_1",
                "type": "function",
                "function": ["name": "execute_ssh_command", "arguments": #"{"zeta":1,"alpha":"ls","mid":true}"#]
            ]]
        ],
        ["role": "tool", "tool_call_id": "call_1", "content": "a.txt"]
    ]

    // MARK: - Anthropic cache_control

    @Test("启用自动缓存时流式请求顶层带 cache_control: ephemeral")
    func anthropicTopLevelCacheControl() throws {
        let strategy = AnthropicFormatStrategy(automaticPromptCaching: true)
        let data = try strategy.buildStreamingRequestBody(messages: messages, model: "claude-test", toolDefinitions: [])
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect((json["cache_control"] as? [String: Any])?["type"] as? String == "ephemeral")
        // 不改动 max_tokens
        #expect(json["max_tokens"] as? Int == 8192)
    }

    @Test("默认（第三方兼容端点）不发送 cache_control")
    func anthropicDefaultOmitsCacheControl() throws {
        let data = try AnthropicFormatStrategy().buildStreamingRequestBody(
            messages: messages, model: "claude-test", toolDefinitions: []
        )
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(json["cache_control"] == nil)
    }

    @Test("仅官方 api.anthropic.com 启用自动缓存")
    func automaticCachingHostGate() {
        #expect(AnthropicFormatStrategy.supportsAutomaticPromptCaching(endpointURL: "https://api.anthropic.com/v1/messages"))
        #expect(AnthropicFormatStrategy.supportsAutomaticPromptCaching(endpointURL: " https://API.anthropic.com/v1/messages "))
        #expect(!AnthropicFormatStrategy.supportsAutomaticPromptCaching(endpointURL: "https://api.deepseek.com/anthropic/v1/messages"))
        #expect(!AnthropicFormatStrategy.supportsAutomaticPromptCaching(endpointURL: "https://api.anthropic.com.evil.example/v1/messages"))
        #expect(!AnthropicFormatStrategy.supportsAutomaticPromptCaching(endpointURL: "not a url"))
    }

    // MARK: - 稳定序列化

    @Test("Anthropic 请求体键序稳定：顶层与 tool_use input 均按字典序")
    func anthropicSortedKeys() throws {
        let strategy = AnthropicFormatStrategy(automaticPromptCaching: true)
        let first = try strategy.buildStreamingRequestBody(messages: messages, model: "claude-test", toolDefinitions: [])
        let second = try strategy.buildStreamingRequestBody(messages: messages, model: "claude-test", toolDefinitions: [])
        #expect(first == second)

        let text = String(data: first, encoding: .utf8)!
        #expect(text.hasPrefix(#"{"cache_control":"#))
        #expect(text.contains(#""input":{"alpha":"ls","mid":true,"zeta":1}"#))
        let maxTokens = try #require(text.range(of: #""max_tokens""#))
        let model = try #require(text.range(of: #""model""#))
        let stream = try #require(text.range(of: #""stream""#))
        #expect(maxTokens.lowerBound < model.lowerBound)
        #expect(model.lowerBound < stream.lowerBound)
    }

    @Test("OpenAI 请求体键序稳定")
    func openAISortedKeys() throws {
        let tools: [[String: Any]] = [[
            "type": "function",
            "function": ["name": "t", "description": "d", "parameters": ["type": "object", "properties": [:]]]
        ]]
        let strategy = OpenAIFormatStrategy()
        let data = try strategy.buildStreamingRequestBody(messages: messages, model: "gpt-test", toolDefinitions: tools)
        let text = String(data: data, encoding: .utf8)!
        #expect(text.hasPrefix(#"{"messages":"#))
        #expect(text.contains(#"{"description":"d","name":"t","parameters":"#))
        let nonStreaming = try strategy.buildNonStreamingRequestBody(
            messages: messages, model: "gpt-test", maxTokens: 10, temperature: nil, reasoningEffort: nil
        )
        #expect(String(data: nonStreaming, encoding: .utf8)!.hasPrefix(#"{"max_tokens":10,"messages":"#))
    }

    // MARK: - usage 解析

    @Test("Anthropic usage：message_start 输入侧 + message_delta 累计输出合并")
    func anthropicUsageMerge() {
        var usage = StreamingTokenUsage()
        usage = AnthropicFormatStrategy.mergeUsage(usage, with: [
            "input_tokens": 12,
            "cache_creation_input_tokens": 0,
            "cache_read_input_tokens": 2048,
            "output_tokens": 1
        ])
        usage = AnthropicFormatStrategy.mergeUsage(usage, with: ["output_tokens": 345])
        #expect(usage == StreamingTokenUsage(
            inputTokens: 12, outputTokens: 345, cacheReadInputTokens: 2048, cacheCreationInputTokens: 0
        ))
    }

    @Test("OpenAI usage：解析 cached_tokens；无 usage 时返回 nil")
    func openAIUsageParse() {
        let chunk: [String: Any] = [
            "choices": [],
            "usage": [
                "prompt_tokens": 2006,
                "completion_tokens": 300,
                "prompt_tokens_details": ["cached_tokens": 1920]
            ]
        ]
        #expect(OpenAIFormatStrategy.parseUsage(from: chunk) == StreamingTokenUsage(
            inputTokens: 2006, outputTokens: 300, cacheReadInputTokens: 1920
        ))
        #expect(OpenAIFormatStrategy.parseUsage(from: ["choices": [["delta": ["content": "hi"]]]]) == nil)
    }
}
