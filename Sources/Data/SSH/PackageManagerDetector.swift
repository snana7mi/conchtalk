/// 文件说明：PackageManagerDetector，统一探测远端包管理器并提供安装命令映射。
import Foundation

/// PackageManagerDetector：
/// 供 SSH 探测与工具提示共用，避免多处维护重复且不一致的探测脚本。
nonisolated enum PackageManagerDetector {
    /// 统一包管理器探测脚本，输出归一化名称（如 apt/dnf/yum）。
    static let detectCommand = """
        if command -v apt-get >/dev/null 2>&1 || command -v apt >/dev/null 2>&1; then echo "apt"; \
        elif command -v dnf >/dev/null 2>&1; then echo "dnf"; \
        elif command -v yum >/dev/null 2>&1; then echo "yum"; \
        elif command -v pacman >/dev/null 2>&1; then echo "pacman"; \
        elif command -v zypper >/dev/null 2>&1; then echo "zypper"; \
        elif command -v apk >/dev/null 2>&1; then echo "apk"; \
        elif command -v brew >/dev/null 2>&1; then echo "brew"; \
        elif command -v port >/dev/null 2>&1; then echo "port"; \
        else echo "unknown"; \
        fi
        """

    /// 执行探测脚本并返回包管理器标识。未知或失败时返回 nil。
    static func detect(using execute: (String) async throws -> String) async -> String? {
        guard let raw = try? await execute(detectCommand) else { return nil }
        return normalize(raw)
    }

    /// 归一化探测输出，统一大小写与别名。
    static func normalize(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty, trimmed != "unknown" else { return nil }
        switch trimmed {
        case "apt-get", "apt":
            return "apt"
        case "dnf":
            return "dnf"
        case "yum":
            return "yum"
        case "pacman":
            return "pacman"
        case "zypper":
            return "zypper"
        case "apk":
            return "apk"
        case "brew":
            return "brew"
        case "port":
            return "port"
        default:
            return nil
        }
    }

}
