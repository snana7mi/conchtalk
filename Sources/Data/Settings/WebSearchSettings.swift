/// 文件说明：WebSearchSettings，管理联网搜索提供商、启用状态与用户 API Key。
import Foundation

/// WebSearchSettings：
/// 开关和当前提供商保存在 UserDefaults，各提供商 API Key 分别保存在本机 Keychain。
/// 仅当用户主动开启且当前提供商的 Key 非空时，联网搜索工具才会暴露给 AI。
nonisolated struct WebSearchSettings: Equatable, Sendable {
    var isEnabled: Bool
    var provider: WebSearchProvider
    var apiKeys: [WebSearchProvider: String]

    var apiKey: String {
        apiKeys[provider] ?? ""
    }

    var isConfigured: Bool {
        isEnabled && !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static let enabledKey = "braveSearchEnabled"
    private static let providerKey = "webSearchProvider"
    static let sharedKeychainService: KeychainServiceProtocol = KeychainService()

    /// 从本机配置读取联网搜索设置；没有提供商记录的旧配置继续使用 Brave。
    static func load(
        keychainService: KeychainServiceProtocol? = nil,
        defaults: UserDefaults = .standard
    ) -> WebSearchSettings {
        let keychain = keychainService ?? sharedKeychainService
        let provider = defaults.string(forKey: providerKey)
            .flatMap(WebSearchProvider.init(rawValue:)) ?? .brave
        let apiKeys = Dictionary(uniqueKeysWithValues: WebSearchProvider.allCases.map { provider in
            (provider, (try? keychain.getWebSearchAPIKey(for: provider)) ?? "")
        })
        return WebSearchSettings(
            isEnabled: defaults.bool(forKey: enabledKey),
            provider: provider,
            apiKeys: apiKeys
        )
    }

    /// 保存开关、当前提供商和各提供商 API Key；空 Key 会删除对应 Keychain 条目。
    func save(
        keychainService: KeychainServiceProtocol? = nil,
        defaults: UserDefaults = .standard
    ) throws {
        let keychain = keychainService ?? Self.sharedKeychainService
        for provider in WebSearchProvider.allCases {
            let key = (apiKeys[provider] ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if key.isEmpty {
                try keychain.deleteWebSearchAPIKey(for: provider)
            } else {
                try keychain.saveWebSearchAPIKey(key, for: provider)
            }
        }
        defaults.set(isEnabled, forKey: Self.enabledKey)
        defaults.set(provider.rawValue, forKey: Self.providerKey)
    }

    /// 返回去除首尾空白后的凭据副本，便于保存后更新界面快照。
    func trimmingAPIKeys() -> WebSearchSettings {
        var copy = self
        copy.apiKeys = copy.apiKeys.mapValues {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return copy
    }
}
