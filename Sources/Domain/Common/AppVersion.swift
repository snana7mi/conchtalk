import Foundation

/// App version information read from the main bundle's Info.plist.
enum AppVersion {
    /// Marketing version (CFBundleShortVersionString), e.g. "1.0.4".
    static var shortVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    /// Build number (CFBundleVersion), e.g. "4".
    static var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    /// Display string such as "1.0.4 (4)".
    static var displayString: String {
        "\(shortVersion) (\(buildNumber))"
    }
}
