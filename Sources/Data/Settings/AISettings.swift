/// 文件说明：AISettings，AI 相关本地配置的持久化。
import Foundation

// MARK: - API Format

/// APIFormat：标识当前使用的 AI API 线上格式。
enum APIFormat: String, CaseIterable, Sendable {
    case openAI = "openai"
    case anthropic = "anthropic"

    var displayName: String {
        switch self {
        case .openAI: return "OpenAI Compatible"
        case .anthropic: return "Anthropic"
        }
    }
}

// MARK: - AI Settings (stored in UserDefaults + Keychain)

/// AISettings：封装 AI 相关本地配置。
/// - API Key 存储于 Keychain（安全存储），其余配置存于 `UserDefaults`。
/// - 首次加载时自动将 UserDefaults 中的旧 API Key 迁移到 Keychain 并清除明文记录。
nonisolated struct AISettings {
    var apiKey: String
    var endpointURL: String
    var modelName: String
    var maxContextTokensK: Int  // Unit: K (e.g. 128 = 128,000 tokens)
    var useLocalConfig: Bool
    var apiFormat: APIFormat
    var permissionLevel: PermissionLevel

    var maxContextTokens: Int { maxContextTokensK * 1000 }

    /// 供无参调用使用的共享 KeychainService 实例（兼容 SettingsView 等无法注入依赖的场景）。
    static let sharedKeychainService: KeychainServiceProtocol = KeychainService()

    /// 从本地配置读取 AI 参数，API Key 从 Keychain 读取。
    /// - Parameter keychainService: Keychain 服务实例；为 `nil` 时使用共享实例。
    /// - Returns: 若未配置则返回包含默认值的设置对象。
    static func load(keychainService: KeychainServiceProtocol? = nil) -> AISettings {
        let keychain = keychainService ?? sharedKeychainService
        let defaults = UserDefaults.standard
        let storedK = defaults.integer(forKey: "aiMaxContextTokensK")

        // 迁移：若 UserDefaults 中存在旧 API Key，迁移至 Keychain 并清除明文
        var apiKey = ""
        if let legacyKey = defaults.string(forKey: "aiAPIKey"), !legacyKey.isEmpty {
            do {
                try keychain.saveAPIKey(legacyKey)
                defaults.removeObject(forKey: "aiAPIKey")
                apiKey = legacyKey
            } catch {
                print("[AISettings] Failed to migrate API key to Keychain: \(error)")
                apiKey = legacyKey
            }
        } else {
            apiKey = (try? keychain.getAPIKey()) ?? ""
        }

        return AISettings(
            apiKey: apiKey,
            endpointURL: defaults.string(forKey: "aiEndpointURL") ?? defaults.string(forKey: "aiBaseURL") ?? "",
            modelName: defaults.string(forKey: "aiModelName") ?? "",
            maxContextTokensK: storedK > 0 ? storedK : 128,
            useLocalConfig: defaults.bool(forKey: "aiUseLocalConfig"),
            apiFormat: APIFormat(rawValue: defaults.string(forKey: "aiAPIFormat") ?? "") ?? .openAI,
            permissionLevel: PermissionLevel(rawValue: defaults.string(forKey: "aiPermissionLevel") ?? "") ?? .standard
        )
    }

    /// 将当前 AI 设置持久化：API Key 写入 Keychain，其余写入 `UserDefaults`。
    /// - Parameter keychainService: Keychain 服务实例；为 `nil` 时使用共享实例。
    /// - Side Effects: 覆盖同名键对应的历史配置值。
    func save(keychainService: KeychainServiceProtocol? = nil) {
        let keychain = keychainService ?? Self.sharedKeychainService
        let defaults = UserDefaults.standard

        // API Key 存入 Keychain；仅在成功后才清除 UserDefaults 中的明文记录
        do {
            if apiKey.isEmpty {
                try keychain.deleteAPIKey()
            } else {
                try keychain.saveAPIKey(apiKey)
            }
            // Keychain 写入成功，清除 UserDefaults 中可能残留的明文
            defaults.removeObject(forKey: "aiAPIKey")
        } catch {
            print("[AISettings] Failed to save API key to Keychain: \(error)")
            // Keychain 写失败时保留 UserDefaults 作为兜底，避免数据丢失
        }

        defaults.set(endpointURL, forKey: "aiEndpointURL")
        defaults.set(modelName, forKey: "aiModelName")
        defaults.set(maxContextTokensK, forKey: "aiMaxContextTokensK")
        defaults.set(useLocalConfig, forKey: "aiUseLocalConfig")
        defaults.set(apiFormat.rawValue, forKey: "aiAPIFormat")
        defaults.set(permissionLevel.rawValue, forKey: "aiPermissionLevel")
    }
}
