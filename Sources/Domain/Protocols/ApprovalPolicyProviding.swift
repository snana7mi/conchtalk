/// 文件说明：ApprovalPolicyProviding，授权策略查询/记忆的抽象契约（供安全门注入）。
import Foundation

nonisolated protocol ApprovalPolicyProviding: Sendable {
    /// 确认前：是否命中持久化 always 规则或本会话 session 信任（strict 直接 false；内部跑 hardening 否决）。
    func autoApproves(serverID: UUID, toolName: String, arguments: [String: Any], permissionLevel: PermissionLevel) async -> Bool
    /// 最窄建议规则；strict / 多段命令 / 不可记忆 → nil。
    func suggestRule(serverID: UUID, toolName: String, arguments: [String: Any], permissionLevel: PermissionLevel) async -> ApprovalRule?
    func save(_ rule: ApprovalRule) async
    func trustForSession(serverID: UUID, matcher: ApprovalMatcher) async
    func clearSessionTrust(serverID: UUID) async
}
