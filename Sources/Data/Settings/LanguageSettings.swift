/// 文件说明：LanguageSettings，应用语言偏好设置模型。
import Foundation

/// 应用支持的语言选项。
nonisolated enum AppLanguage: String, CaseIterable, Sendable {
    case system
    case en
    case zhHans = "zh-Hans"
    case ja

    /// 用于 UI 展示的名称（固定文字，不随本地化变化）。
    var displayName: String {
        switch self {
        case .system: String(localized: "Follow System")
        case .en: "English"
        case .zhHans: "中文"
        case .ja: "日本語"
        }
    }
}

/// LanguageSettings：封装语言偏好的本地存储。
nonisolated struct LanguageSettings: Sendable {
    var language: AppLanguage

    private static let key = "appLanguage"

    // 缓存：避免每次本地化访问都读取 UserDefaults
    private static var _cachedLanguage: AppLanguage?
    private static var _cachedBundle: Bundle?
    private static var _cachedLocale: Locale?

    static func load() -> LanguageSettings {
        let raw = UserDefaults.standard.string(forKey: key) ?? AppLanguage.system.rawValue
        let lang = AppLanguage(rawValue: raw) ?? .system
        return LanguageSettings(language: lang)
    }

    func save() {
        UserDefaults.standard.set(language.rawValue, forKey: LanguageSettings.key)
        // 保存时清除缓存，下次访问时重建
        LanguageSettings._cachedLanguage = nil
        LanguageSettings._cachedBundle = nil
        LanguageSettings._cachedLocale = nil
    }

    /// 当前应用语言对应的 Locale，供格式化使用。
    static var currentLocale: Locale {
        if let cached = _cachedLocale { return cached }
        let locale = load().language.locale ?? .autoupdatingCurrent
        _cachedLocale = locale
        return locale
    }

    /// 当前应用语言对应的 Bundle，供 `String(localized:bundle:)` 查找翻译。
    /// - Note: `locale:` 只影响插值格式化，`bundle:` 才决定使用哪种语言翻译。
    ///
    /// 英语是开发语言（Development Language），Xcode 不会生成 `en.lproj`，
    /// 键本身即为英文文本。此时返回一个空 bundle，使 `String(localized:bundle:)`
    /// 找不到翻译而回落到键值（即英文原文）。
    static var currentBundle: Bundle {
        if let cached = _cachedBundle { return cached }
        let language = load().language
        let bundle: Bundle
        if language == .system {
            bundle = .main
        } else if let path = Bundle.main.path(forResource: language.rawValue, ofType: "lproj"),
                  let lproj = Bundle(path: path) {
            bundle = lproj
        } else if language == .en {
            bundle = LanguageSettings.emptyBundle
        } else {
            bundle = .main
        }
        _cachedBundle = bundle
        return bundle
    }

    /// 用于英语回落的空 bundle：不含任何 .strings 文件，
    /// 使 `String(localized:bundle:)` 始终返回键值（即英文原文）。
    private static let emptyBundle: Bundle = {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConchTalk_EmptyBundle.bundle")
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return Bundle(url: url) ?? .main
    }()
}

nonisolated extension AppLanguage {
    /// 返回对应的 Locale，跟随系统时返回 nil。
    var locale: Locale? {
        switch self {
        case .system: nil
        case .en: Locale(identifier: "en")
        case .zhHans: Locale(identifier: "zh-Hans")
        case .ja: Locale(identifier: "ja")
        }
    }
}
