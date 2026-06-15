/// 文件说明：ApprovalRule，一条按服务器记忆的「始终允许」授权规则及其匹配器。
import Foundation

/// ApprovalMatcher：规则如何匹配未来的工具调用。
nonisolated enum ApprovalMatcher: Sendable, Equatable, Hashable, Codable {
    /// execute_ssh_command：候选命令（单段）的前导 argv token 须逐个等于 tokens；尾部自由。
    case commandPrefix(tokens: [String])
    /// write_file / edit_file：候选 path 规范化后等于 prefix（recursive=false）或位于其下（recursive=true）。
    case pathPrefix(prefix: String, recursive: Bool)
}

/// ApprovalRule：
/// 用户对某个具体命令模式/路径作出的「始终允许」决定，按 serverID 隔离、可同步、可撤销。
nonisolated struct ApprovalRule: Identifiable, Sendable, Equatable, Codable {
    let id: UUID
    let serverID: UUID
    var toolName: String
    var matcher: ApprovalMatcher
    var displayLabel: String
    var createdAt: Date
    var modifiedAt: Date
}
