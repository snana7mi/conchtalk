/// 文件说明：NoOpApprovalPolicy，授权策略的退化实现：永远不自动放行、不建议规则、不记忆。
import Foundation

/// NoOpApprovalPolicy：
/// 当未注入真实 `ApprovalPolicyStore` 时使用的安全默认实现。
/// 语义为「永远弹窗确认、永不记忆」——`autoApproves` 恒 false、`suggestRule` 恒 nil，
/// 其余记忆/会话信任操作均为空操作，保证现有调用方/测试在不传策略时行为不变且不留痕。
nonisolated struct NoOpApprovalPolicy: ApprovalPolicyProviding {
    init() {}

    func autoApproves(serverID: UUID, toolName: String, arguments: [String: Any], permissionLevel: PermissionLevel) async -> Bool {
        false
    }

    func suggestRule(serverID: UUID, toolName: String, arguments: [String: Any], permissionLevel: PermissionLevel) async -> ApprovalRule? {
        nil
    }

    func save(_ rule: ApprovalRule) async {}

    func trustForSession(serverID: UUID, matcher: ApprovalMatcher) async {}

    func clearSessionTrust(serverID: UUID) async {}
}
