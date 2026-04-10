/// 文件说明：DLCSettings，DLC 代理模式的全局与单服务器开关持久化。
import Foundation

/// DLCSettings：管理 DLC 代理模式的开关状态。
/// 前置条件：登录 + paid + 云同步已开启。
enum DLCSettings {
    private static let globalKey = "DLCSettings.globalEnabled"
    private static let overridesKey = "DLCSettings.serverOverrides"

    nonisolated(unsafe) static var isGlobalEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: globalKey) }
        set { UserDefaults.standard.set(newValue, forKey: globalKey) }
    }

    static func serverOverride(for serverID: UUID) -> Bool? {
        loadOverrides()[serverID.uuidString]
    }

    static func setServerOverride(for serverID: UUID, enabled: Bool) {
        var overrides = loadOverrides()
        overrides[serverID.uuidString] = enabled
        saveOverrides(overrides)
    }

    static func clearServerOverride(for serverID: UUID) {
        var overrides = loadOverrides()
        overrides.removeValue(forKey: serverID.uuidString)
        saveOverrides(overrides)
    }

    static func clearAllServerOverrides() {
        UserDefaults.standard.removeObject(forKey: overridesKey)
    }

    static func isEffectivelyEnabled(for serverID: UUID) -> Bool {
        serverOverride(for: serverID) ?? isGlobalEnabled
    }

    static func checkPrerequisites(isLoggedIn: Bool, isPaid: Bool, isSyncEnabled: Bool) -> String? {
        if !isLoggedIn {
            return String(localized: "Sign in to use DLC Agent", bundle: LanguageSettings.currentBundle)
        }
        if !isPaid {
            return String(localized: "DLC Agent requires a paid subscription", bundle: LanguageSettings.currentBundle)
        }
        if !isSyncEnabled {
            return String(localized: "Enable Cloud Sync before using DLC Agent", bundle: LanguageSettings.currentBundle)
        }
        return nil
    }

    private static func loadOverrides() -> [String: Bool] {
        guard let data = UserDefaults.standard.data(forKey: overridesKey),
              let dict = try? JSONDecoder().decode([String: Bool].self, from: data) else { return [:] }
        return dict
    }

    private static func saveOverrides(_ overrides: [String: Bool]) {
        guard let data = try? JSONEncoder().encode(overrides) else { return }
        UserDefaults.standard.set(data, forKey: overridesKey)
    }
}
