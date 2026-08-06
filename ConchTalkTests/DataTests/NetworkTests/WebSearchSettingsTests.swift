/// 文件说明：WebSearchSettingsTests，验证联网搜索提供商与 Keychain 凭据持久化。
import Testing
@testable import ConchTalk
import Foundation

@Suite("WebSearchSettings", .serialized)
struct WebSearchSettingsTests {
    private func makeDefaults() throws -> (UserDefaults, String) {
        let suiteName = "WebSearchSettingsTests.\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: suiteName)), suiteName)
    }

    @Test("保存并加载启用状态、提供商和对应 API Key")
    func saveAndLoad() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let keychain = MockKeychainService()
        let settings = WebSearchSettings(
            isEnabled: true,
            provider: .exa,
            apiKeys: [.brave: "brave-key", .exa: " exa-key "]
        )

        try settings.save(keychainService: keychain, defaults: defaults)
        let loaded = WebSearchSettings.load(keychainService: keychain, defaults: defaults)

        #expect(loaded.provider == .exa)
        #expect(loaded.apiKey == "exa-key")
        #expect(loaded.apiKeys[.brave] == "brave-key")
        #expect(loaded.isConfigured)
    }

    @Test("关闭搜索时保留各提供商 Key 但配置不可用")
    func disabledKeepsKeys() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let keychain = MockKeychainService()

        try WebSearchSettings(
            isEnabled: false,
            provider: .anySearch,
            apiKeys: [.anySearch: "anysearch-key"]
        ).save(keychainService: keychain, defaults: defaults)
        let loaded = WebSearchSettings.load(keychainService: keychain, defaults: defaults)

        #expect(!loaded.isEnabled)
        #expect(loaded.apiKey == "anysearch-key")
        #expect(!loaded.isConfigured)
    }

    @Test("清空某个提供商的 Key 时只删除对应凭据")
    func emptyKeyDeletesSelectedCredential() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let keychain = MockKeychainService()
        try keychain.saveWebSearchAPIKey("brave-key", for: .brave)
        try keychain.saveWebSearchAPIKey("old-exa-key", for: .exa)

        try WebSearchSettings(
            isEnabled: false,
            provider: .exa,
            apiKeys: [.brave: "brave-key", .exa: "  "]
        ).save(keychainService: keychain, defaults: defaults)

        #expect(try keychain.getWebSearchAPIKey(for: .brave) == "brave-key")
        #expect(try keychain.getWebSearchAPIKey(for: .exa) == nil)
    }

    @Test("旧版配置默认迁移为 Brave")
    func legacyConfigurationDefaultsToBrave() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let keychain = MockKeychainService()
        defaults.set(true, forKey: "braveSearchEnabled")
        try keychain.saveWebSearchAPIKey("legacy-brave-key", for: .brave)

        let loaded = WebSearchSettings.load(keychainService: keychain, defaults: defaults)

        #expect(loaded.provider == .brave)
        #expect(loaded.apiKey == "legacy-brave-key")
        #expect(loaded.isConfigured)
    }
}
