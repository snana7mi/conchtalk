/// 文件说明：ApprovalPolicyStore，授权策略的运行时实现：持久化 always 规则 + 内存 session 信任。
import Foundation

/// ApprovalPolicyStore：
/// 实现 ApprovalPolicyProviding。autoApproves 先判 strict、再经 ApprovalMatching（内含 hardening 否决）
/// 比对 session 信任与持久化规则。规则持久化委托 SwiftDataStore；session 信任为内存态、按服务器。
actor ApprovalPolicyStore: ApprovalPolicyProviding {
    private let store: SwiftDataStore
    private var sessionTrust: [UUID: Set<ApprovalMatcher>] = [:]

    init(store: SwiftDataStore) { self.store = store }

    func autoApproves(serverID: UUID, toolName: String, arguments: [String: Any], permissionLevel: PermissionLevel) async -> Bool {
        guard permissionLevel != .strict else { return false }
        // session 信任
        if let set = sessionTrust[serverID],
           set.contains(where: { ApprovalMatching.matches(matcher: $0, toolName: toolName, arguments: arguments) }) {
            return true
        }
        // 持久化规则
        let rules = (try? await store.fetchApprovalRules(forServer: serverID)) ?? []
        return rules.contains { $0.toolName == toolName &&
            ApprovalMatching.matches(matcher: $0.matcher, toolName: toolName, arguments: arguments) }
    }

    func suggestRule(serverID: UUID, toolName: String, arguments: [String: Any], permissionLevel: PermissionLevel) async -> ApprovalRule? {
        guard permissionLevel != .strict else { return nil }
        guard let matcher = ApprovalMatching.suggestedMatcher(toolName: toolName, arguments: arguments) else { return nil }
        return ApprovalRule(id: UUID(), serverID: serverID, toolName: toolName, matcher: matcher,
                            displayLabel: ApprovalMatching.suggestedLabel(matcher: matcher, toolName: toolName),
                            createdAt: Date(), modifiedAt: Date())
    }

    func save(_ rule: ApprovalRule) async {
        try? await store.saveApprovalRule(rule)
    }

    func trustForSession(serverID: UUID, matcher: ApprovalMatcher) async {
        sessionTrust[serverID, default: []].insert(matcher)
    }

    func clearSessionTrust(serverID: UUID) async {
        sessionTrust[serverID] = nil
    }

    // MARK: - UI 读/删（非 protocol，供 Trusted Actions 页）
    func allRules(forServer serverID: UUID) async -> [ApprovalRule] {
        (try? await store.fetchApprovalRules(forServer: serverID)) ?? []
    }
    func delete(ruleID: UUID) async {
        try? await store.deleteApprovalRule(ruleID)
    }
}
