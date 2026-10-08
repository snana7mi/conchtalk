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

// MARK: - Thinking Level

/// AIThinkingLevel：用户选择的思考 / 推理力度。
/// - `modelDefault`：不发送任何思考参数，完全沿用模型默认行为（Claude 5.x 默认即开启思考）。
/// - 其余档位：Anthropic 映射为 adaptive + `output_config.effort` 或 manual `budget_tokens`；
///   OpenAI 兼容格式映射为 `reasoning_effort`。
nonisolated enum AIThinkingLevel: String, CaseIterable, Sendable {
    case modelDefault = "default"
    case low
    case medium
    case high

    /// Anthropic effort / OpenAI reasoning_effort 取值；`modelDefault` 为 nil（不发送）。
    var effortValue: String? {
        switch self {
        case .modelDefault: return nil
        case .low: return "low"
        case .medium: return "medium"
        case .high: return "high"
        }
    }
}

extension AIThinkingLevel {
    /// 本地化展示名称（仅供 UI 使用）。
    var displayName: String {
        switch self {
        case .modelDefault: return String(localized: "Model Default", bundle: LanguageSettings.currentBundle)
        case .low: return String(localized: "Low", bundle: LanguageSettings.currentBundle)
        case .medium: return String(localized: "Medium", bundle: LanguageSettings.currentBundle)
        case .high: return String(localized: "High", bundle: LanguageSettings.currentBundle)
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
    var apiFormat: APIFormat
    var permissionLevel: PermissionLevel
    /// 单次回复的最大输出 token（仅 Anthropic 格式发送 max_tokens）；0 表示按模型自动选择。
    var maxOutputTokens: Int = 0
    /// 思考 / 推理力度，默认不发送任何思考参数。
    var thinkingLevel: AIThinkingLevel = .modelDefault

    var maxContextTokens: Int { maxContextTokensK * 1000 }

    /// 解析 Anthropic 请求实际使用的 max_tokens：用户值优先（下限 1024），否则按模型自动。
    func resolvedMaxOutputTokens() -> Int {
        maxOutputTokens > 0
            ? max(maxOutputTokens, 1024)
            : AnthropicModelCapabilities.defaultMaxOutputTokens(for: modelName)
    }

    /// 实际用于压缩判定的上下文预算（见 `effectiveMaxContextTokens(configured:modelName:maxOutputTokens:)`）。
    var effectiveMaxContextTokens: Int {
        Self.effectiveMaxContextTokens(
            configured: maxContextTokens,
            modelName: modelName,
            maxOutputTokens: resolvedMaxOutputTokens()
        )
    }

    /// 上下文预算 = 用户设置，但不超过已知模型窗口减去单次输出上限
    ///（Anthropic 要求输入 + max_tokens 不超过窗口，否则请求被拒）。未知模型直接使用用户设置。
    static func effectiveMaxContextTokens(configured: Int, modelName: String, maxOutputTokens: Int) -> Int {
        guard let window = AnthropicModelCapabilities.contextWindow(for: modelName) else { return configured }
        return max(min(configured, window - maxOutputTokens), 8_000)
    }

    /// 只读取上下文窗口相关设置，不触碰 Keychain 或执行旧凭据迁移。
    /// 已知模型（Claude）时按模型窗口封顶，见 `effectiveMaxContextTokens`。
    static func loadMaxContextTokens(defaults: UserDefaults = .standard) -> Int {
        let storedK = defaults.integer(forKey: "aiMaxContextTokensK")
        let configured = (storedK > 0 ? storedK : 128) * 1000
        let modelName = defaults.string(forKey: "aiModelName") ?? ""
        let storedOutput = max(defaults.integer(forKey: "aiMaxOutputTokens"), 0)
        let maxOutput = storedOutput > 0
            ? max(storedOutput, 1024)
            : AnthropicModelCapabilities.defaultMaxOutputTokens(for: modelName)
        return effectiveMaxContextTokens(configured: configured, modelName: modelName, maxOutputTokens: maxOutput)
    }

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
            apiFormat: APIFormat(rawValue: defaults.string(forKey: "aiAPIFormat") ?? "") ?? .openAI,
            permissionLevel: PermissionLevel(rawValue: defaults.string(forKey: "aiPermissionLevel") ?? "") ?? .standard,
            maxOutputTokens: max(defaults.integer(forKey: "aiMaxOutputTokens"), 0),
            thinkingLevel: AIThinkingLevel(rawValue: defaults.string(forKey: "aiThinkingLevel") ?? "") ?? .modelDefault
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
        defaults.set(apiFormat.rawValue, forKey: "aiAPIFormat")
        defaults.set(permissionLevel.rawValue, forKey: "aiPermissionLevel")
        defaults.set(max(maxOutputTokens, 0), forKey: "aiMaxOutputTokens")
        defaults.set(thinkingLevel.rawValue, forKey: "aiThinkingLevel")
    }
}
