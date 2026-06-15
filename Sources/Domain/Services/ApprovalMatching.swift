/// 文件说明：ApprovalMatching，纯函数：判定规则是否命中当前调用、并给出最窄建议规则。
import Foundation

/// ApprovalMatching：
/// 授权规则匹配的唯一权威实现（纯、可测）。命令匹配内置 hardening 否决与单段限制，
/// 路径匹配内置规范化与 `..` 拒绝，确保规则绝不绕过安全网。
nonisolated enum ApprovalMatching {

    /// 判定 matcher 是否命中本次工具调用。
    static func matches(matcher: ApprovalMatcher, toolName: String, arguments: [String: Any]) -> Bool {
        switch matcher {
        case .commandPrefix(let tokens):
            guard toolName == "execute_ssh_command" else { return false }
            guard let cmd = (arguments["command"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !cmd.isEmpty else { return false }
            // 安全否决优先于任何规则
            if CommandHardening.isForbidden(cmd) { return false }
            if CommandHardening.hasInjectionOrRedirection(cmd) { return false }
            // 仅单段命令可被规则匹配
            let segments = CommandHardening.splitRawSegments(cmd)
            guard segments.count == 1 else { return false }
            let candidate = CommandHardening.tokenize(segments[0])
            guard !tokens.isEmpty, candidate.count >= tokens.count else { return false }
            return Array(candidate.prefix(tokens.count)) == tokens

        case .pathPrefix(let prefix, let recursive):
            guard toolName == "write_file" || toolName == "edit_file" else { return false }
            guard let raw = arguments["path"] as? String, let path = normalizePath(raw) else { return false }
            let normPrefix = normalizePath(prefix) ?? prefix
            if recursive {
                if path == normPrefix { return true }
                let base = normPrefix.hasSuffix("/") ? normPrefix : normPrefix + "/"
                return path.hasPrefix(base)
            } else {
                return path == normPrefix
            }
        }
    }

    /// 为本次调用构建最窄建议规则；命令多段 / 命中 hardening / 无法解析 → nil。
    static func suggestedMatcher(toolName: String, arguments: [String: Any]) -> ApprovalMatcher? {
        switch toolName {
        case "execute_ssh_command":
            guard let cmd = (arguments["command"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !cmd.isEmpty else { return nil }
            if CommandHardening.isForbidden(cmd) || CommandHardening.hasInjectionOrRedirection(cmd) { return nil }
            let segments = CommandHardening.splitRawSegments(cmd)
            guard segments.count == 1 else { return nil }
            let tokens = CommandHardening.tokenize(segments[0])
            guard !tokens.isEmpty else { return nil }
            return .commandPrefix(tokens: tokens)
        case "write_file", "edit_file":
            guard let raw = arguments["path"] as? String, let path = normalizePath(raw) else { return nil }
            return .pathPrefix(prefix: path, recursive: false)
        default:
            return nil
        }
    }

    /// 建议规则的人类可读标签（仅 UI；英文模板，本地化在卡片层处理展示）。
    static func suggestedLabel(matcher: ApprovalMatcher, toolName: String) -> String {
        switch matcher {
        case .commandPrefix(let tokens): tokens.joined(separator: " ")
        case .pathPrefix(let prefix, let recursive): recursive ? "\(prefix)/…" : prefix
        }
    }

    /// 规范化绝对路径：折叠 `.` 与多余分隔符；含 `..` 返回 nil（拒绝穿越）。
    static func normalizePath(_ raw: String) -> String? {
        let comps = raw.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if comps.contains("..") { return nil }
        let kept = comps.filter { $0 != "." }
        let prefix = raw.hasPrefix("/") ? "/" : ""
        return prefix + kept.joined(separator: "/")
    }
}
