/// 文件说明：ServerCommandPolicy，某一台服务器上用户自定义的命令允许/拒绝列表。
import Foundation

/// CommandPolicyList：允许列表或拒绝列表。
nonisolated enum CommandPolicyList: Sendable, Equatable {
    case allow
    case deny
}

/// CommandPolicyDecision：用户词表相对内置禁止规则的结论。
nonisolated enum CommandPolicyDecision: Sendable, Equatable {
    /// 命中内置禁止模式。允许列表不能覆盖。
    case forbidden
    /// 命中拒绝列表。压过允许列表、内置放行和「始终允许」。
    case denied
    /// 命中允许列表，且命令不是禁止命令。
    case allowed
    /// 词表没有意见，沿用工具自己的分级。
    case unspecified
}

/// CommandPolicyEditError：编辑列表时的校验失败原因。界面负责把它们翻成用户语言。
nonisolated enum CommandPolicyEditError: Sendable, Equatable {
    case empty
    case duplicate
    case forbiddenAllow
    case saveFailed
}

/// ServerCommandPolicy：
/// 按服务器保存的命令词表。拒绝列表优先于允许列表和「始终允许」规则；
/// 允许列表不能放过 `CommandHardening` 判定为禁止的命令。
nonisolated struct ServerCommandPolicy: Sendable, Equatable, Codable {
    var allow: [String]
    var deny: [String]

    static let empty = ServerCommandPolicy(allow: [], deny: [])

    init(allow: [String] = [], deny: [String] = []) {
        self.allow = allow
        self.deny = deny
    }

    /// 追加一条已修剪的命令。禁止命令不能进入允许列表；空串和重复条目会被拒绝。
    func inserting(_ raw: String, into list: CommandPolicyList) -> Result<ServerCommandPolicy, CommandPolicyEditError> {
        let entry = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !entry.isEmpty else { return .failure(.empty) }
        var copy = self
        switch list {
        case .allow:
            if CommandHardening.isForbidden(entry) { return .failure(.forbiddenAllow) }
            if copy.allow.contains(entry) { return .failure(.duplicate) }
            copy.allow.append(entry)
        case .deny:
            if copy.deny.contains(entry) { return .failure(.duplicate) }
            copy.deny.append(entry)
        }
        return .success(copy)
    }
}
