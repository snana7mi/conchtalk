/// 文件说明：AISettingsTests，验证用户自有 AI 配置持久化。
import Testing
@testable import ConchTalk
import Foundation

/// AISettingsTests：
/// 覆盖 endpoint、API key、model 与 API 格式的本地保存。
@Suite("AISettings", .serialized)
struct AISettingsTests {
    private let keys = [
        "aiAPIKey",
        "aiEndpointURL",
        "aiBaseURL",
        "aiModelName",
        "aiMaxContextTokensK",
        "aiAPIFormat",
        "aiPermissionLevel",
    ]

    private func clearDefaults() {
        for key in keys {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    @Test("保存并加载用户自有 AI 路线")
    func savesAndLoadsOwnedAIRoute() throws {
        clearDefaults()
        defer { clearDefaults() }
        let keychain = MockKeychainService()
        let settings = AISettings(
            apiKey: "sk-user-owned",
            endpointURL: "https://ai.example.com/v1/chat/completions",
            modelName: "user-model",
            maxContextTokensK: 64,
            apiFormat: .openAI,
            permissionLevel: .strict
        )

        settings.save(keychainService: keychain)
        let loaded = AISettings.load(keychainService: keychain)

        #expect(loaded.apiKey == "sk-user-owned")
        #expect(loaded.endpointURL == "https://ai.example.com/v1/chat/completions")
        #expect(loaded.modelName == "user-model")
        #expect(loaded.maxContextTokensK == 64)
        #expect(loaded.apiFormat == .openAI)
        #expect(loaded.permissionLevel == .strict)
        #expect(UserDefaults.standard.object(forKey: "aiAPIKey") == nil)
    }

    @Test("上下文窗口可独立读取且使用 token 单位")
    func loadsMaxContextTokensWithoutFullSettings() {
        clearDefaults()
        defer { clearDefaults() }

        #expect(AISettings.loadMaxContextTokens() == 128_000)
        UserDefaults.standard.set(64, forKey: "aiMaxContextTokensK")
        #expect(AISettings.loadMaxContextTokens() == 64_000)
    }
}
