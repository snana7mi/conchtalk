/// 文件说明：AIStreamingIntegrationTests，真实 AI API 流式调用的集成测试。
@testable import ConchTalk
import Foundation
import Testing

/// AIStreamingIntegrationTests：
/// 验证 AIProxyService 的流式响应能力，包括基本流式输出、内容拼接、
/// 工具定义兼容性、错误处理和取消安全性。
@Suite(.tags(.integration), .serialized)
struct AIStreamingIntegrationTests {

    // MARK: - basicStreaming

    /// 验证发送简单消息后，流中至少包含 `.content` 和 `.done` 事件。
    @Test
    func basicStreaming() async throws {
        let config = try #require(IntegrationTestConfig.load())
        let (service, _) = config.makeAIService()
        defer { IntegrationTestConfig.cleanupAISettings() }

        let stream = service.sendMessageStreaming(
            "Say exactly: hello world",
            conversationHistory: [],
            serverContext: ""
        )

        var hasContent = false
        var hasDone = false

        for await delta in stream {
            switch delta {
            case .content:
                hasContent = true
            case .done:
                hasDone = true
            case .error(let error):
                Issue.record("Unexpected error in stream: \(error)")
            default:
                break
            }
        }

        #expect(hasContent, "Stream should contain at least one .content delta")
        #expect(hasDone, "Stream should end with a .done delta")
    }

    // MARK: - streamingCollectsContent

    /// 验证拼接所有 `.content` 增量后得到非空的连贯文本。
    @Test
    func streamingCollectsContent() async throws {
        let config = try #require(IntegrationTestConfig.load())
        let (service, _) = config.makeAIService()
        defer { IntegrationTestConfig.cleanupAISettings() }

        let stream = service.sendMessageStreaming(
            "Say exactly: hello world",
            conversationHistory: [],
            serverContext: ""
        )

        var collectedContent = ""

        for await delta in stream {
            switch delta {
            case .content(let text):
                collectedContent += text
            case .error(let error):
                Issue.record("Unexpected error in stream: \(error)")
            default:
                break
            }
        }

        #expect(!collectedContent.isEmpty, "Collected content should be non-empty")
        #expect(collectedContent.lowercased().contains("hello"), "Content should contain 'hello'")
    }

    // MARK: - streamingWithToolDefinitions

    /// 验证携带工具定义时流式输出不会崩溃，且能正常产出 delta。
    @Test
    func streamingWithToolDefinitions() async throws {
        let config = try #require(IntegrationTestConfig.load())

        let tools: [any ToolProtocol] = [
            ExecuteSSHCommandTool(),
            ReadFileTool(),
        ]
        let toolRegistry = ToolRegistry(tools: tools)

        let (service, _) = config.makeAIService(toolRegistry: toolRegistry)
        defer { IntegrationTestConfig.cleanupAISettings() }

        let stream = service.sendMessageStreaming(
            "What tools do you have available? Just list their names briefly.",
            conversationHistory: [],
            serverContext: ""
        )

        var deltaCount = 0

        for await delta in stream {
            switch delta {
            case .content, .reasoning, .toolCall, .done, .contextCompressing:
                deltaCount += 1
            case .error(let error):
                Issue.record("Unexpected error in stream: \(error)")
            }
        }

        #expect(deltaCount > 0, "Stream should produce at least one delta")
    }

    // MARK: - streamingErrorHandling

    /// 验证使用无效 API Key 时，流中包含 `.error` 事件。
    @Test
    func streamingErrorHandling() async throws {
        _ = try #require(IntegrationTestConfig.load())

        // 手动配置无效的 API Key
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: "aiUseLocalConfig")
        defaults.set("https://api.openai.com/v1", forKey: "aiEndpointURL")
        defaults.set("gpt-4o-mini", forKey: "aiModelName")
        defaults.set("openai", forKey: "aiAPIFormat")

        let mockKeychain = MockKeychainService()
        try mockKeychain.saveAPIKey("sk-invalid-key-for-testing-\(UUID().uuidString)")

        let service = AIProxyService(
            keychainService: mockKeychain,
            toolRegistry: ToolRegistry(tools: []),
            skillRegistry: SkillRegistry(preloaded: [])
        )
        defer { IntegrationTestConfig.cleanupAISettings() }

        let stream = service.sendMessageStreaming(
            "Hello",
            conversationHistory: [],
            serverContext: ""
        )

        var hasError = false

        for await delta in stream {
            if case .error = delta {
                hasError = true
            }
        }

        #expect(hasError, "Stream should contain an .error delta for invalid API key")
    }

    // MARK: - streamingCancellation

    /// 验证在流式输出过程中取消 Task 不会导致崩溃。
    @Test
    func streamingCancellation() async throws {
        let config = try #require(IntegrationTestConfig.load())
        let (service, _) = config.makeAIService()
        defer { IntegrationTestConfig.cleanupAISettings() }

        let task = Task {
            let stream = service.sendMessageStreaming(
                "Write a very long essay about the history of computing, covering every decade from the 1940s to the 2020s in great detail.",
                conversationHistory: [],
                serverContext: ""
            )

            for await delta in stream {
                switch delta {
                case .content, .reasoning:
                    // 收到第一个内容增量后立即退出
                    return
                case .error:
                    // 取消导致的错误也是预期行为
                    return
                default:
                    break
                }
            }
        }

        // 等待 task 收到第一个 delta 后自行结束，或超时后取消
        let timeoutTask = Task {
            try await Task.sleep(for: .seconds(15))
            task.cancel()
        }

        _ = await task.value
        timeoutTask.cancel()

        // 如果执行到这里没有崩溃，测试就通过了
    }
}
