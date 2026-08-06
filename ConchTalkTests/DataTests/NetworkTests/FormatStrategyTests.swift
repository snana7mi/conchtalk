/// 文件说明：FormatStrategyTests，测试 OpenAI 和 Anthropic API 格式策略的请求构建与认证头生成。
import Testing
@testable import ConchTalk
import Foundation

// MARK: - OpenAIFormatStrategy

@Suite("OpenAIFormatStrategy")
struct OpenAIFormatStrategyTests {

    private let strategy = OpenAIFormatStrategy()

    @Test("sets Authorization Bearer header")
    func setsAuthorizationBearerHeader() {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        strategy.setAuthHeaders(on: &request, apiKey: "sk-test-key")

        let authHeader = request.value(forHTTPHeaderField: "Authorization")
        #expect(authHeader == "Bearer sk-test-key")
    }

    @Test("streaming body contains stream=true")
    func streamingBodyContainsStreamTrue() throws {
        let messages: [[String: Any]] = [
            ["role": "user", "content": "Hello"]
        ]
        let data = try strategy.buildStreamingRequestBody(
            messages: messages,
            model: "gpt-4o",
            toolDefinitions: []
        )

        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(json["stream"] as? Bool == true)
    }

    @Test("streaming body contains model name")
    func streamingBodyContainsModelName() throws {
        let messages: [[String: Any]] = [
            ["role": "user", "content": "Hello"]
        ]
        let data = try strategy.buildStreamingRequestBody(
            messages: messages,
            model: "gpt-4o",
            toolDefinitions: []
        )

        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(json["model"] as? String == "gpt-4o")
    }

    @Test("streaming body omits model when empty")
    func streamingBodyOmitsEmptyModel() throws {
        let messages: [[String: Any]] = [["role": "user", "content": "Hi"]]
        let data = try strategy.buildStreamingRequestBody(
            messages: messages,
            model: "",
            toolDefinitions: []
        )

        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(json["model"] == nil)
    }

    @Test("streaming body includes tools when provided")
    func streamingBodyIncludesTools() throws {
        let messages: [[String: Any]] = [["role": "user", "content": "Hi"]]
        let tools: [[String: Any]] = [
            ["type": "function", "function": ["name": "execute_ssh_command"]]
        ]
        let data = try strategy.buildStreamingRequestBody(
            messages: messages,
            model: "gpt-4o",
            toolDefinitions: tools
        )

        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect((json["tools"] as? [[String: Any]])?.isEmpty == false)
    }
}

// MARK: - AnthropicFormatStrategy

@Suite("AnthropicFormatStrategy")
struct AnthropicFormatStrategyTests {

    private let strategy = AnthropicFormatStrategy()

    @Test("sets x-api-key header")
    func setsXApiKeyHeader() {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        strategy.setAuthHeaders(on: &request, apiKey: "sk-ant-test")

        let apiKeyHeader = request.value(forHTTPHeaderField: "x-api-key")
        #expect(apiKeyHeader == "sk-ant-test")
    }

    @Test("sets anthropic-version header")
    func setsAnthropicVersionHeader() {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        strategy.setAuthHeaders(on: &request, apiKey: "sk-ant-test")

        let versionHeader = request.value(forHTTPHeaderField: "anthropic-version")
        #expect(versionHeader == "2023-06-01")
    }

    @Test("streaming body contains stream=true")
    func streamingBodyContainsStreamTrue() throws {
        let messages: [[String: Any]] = [
            ["role": "user", "content": "Hello"]
        ]
        let data = try strategy.buildStreamingRequestBody(
            messages: messages,
            model: "claude-3-5-sonnet-20241022",
            toolDefinitions: []
        )

        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(json["stream"] as? Bool == true)
    }

    @Test("streaming body contains max_tokens=8192")
    func streamingBodyContainsMaxTokens() throws {
        let messages: [[String: Any]] = [
            ["role": "user", "content": "Hello"]
        ]
        let data = try strategy.buildStreamingRequestBody(
            messages: messages,
            model: "claude-3-5-sonnet-20241022",
            toolDefinitions: []
        )

        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(json["max_tokens"] as? Int == 8192)
    }

    @Test("streaming body contains model name")
    func streamingBodyContainsModelName() throws {
        let modelName = "claude-3-5-sonnet-20241022"
        let messages: [[String: Any]] = [["role": "user", "content": "Hi"]]
        let data = try strategy.buildStreamingRequestBody(
            messages: messages,
            model: modelName,
            toolDefinitions: []
        )

        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(json["model"] as? String == modelName)
    }
}
