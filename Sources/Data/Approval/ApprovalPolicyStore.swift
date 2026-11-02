/// 文件说明：ApprovalPolicyStore，授权策略的运行时实现：持久化 always 规则 + 内存 session 信任。
import Foundation

/// ApprovalPolicyStore：
/// 实现 ApprovalPolicyProviding。autoApproves 先判 strict、再经 ApprovalMatching（内含 hardening 否决）
/// 比对 session 信任与持久化规则。规则持久化委托 SwiftDataStore；session 信任为内存态、按服务器。
actor ApprovalPolicyStore: ApprovalPolicyProviding {
    private let store: SwiftDataStore
    private let commandPolicies: CommandPolicyStore
    private var sessionTrust: [UUID: Set<ApprovalMatcher>] = [:]

    init(store: SwiftDataStore, commandPolicies: CommandPolicyStore = CommandPolicyStore()) {
        self.store = store
        self.commandPolicies = commandPolicies
    }

    func autoApproves(serverID: UUID, toolName: String, arguments: [String: Any], permissionLevel: PermissionLevel) async -> Bool {
        guard permissionLevel != .strict else { return false }
        if toolName == "execute_ssh_command", let command = arguments["command"] as? String {
            let policy = await commandPolicies.policy(for: serverID)
            switch CommandHardening.policyDecision(command: command, policy: policy) {
            case .forbidden, .denied:
                return false
            case .allowed:
                return true
            case .unspecified:
                break
            }
        }
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
        if toolName == "execute_ssh_command", let command = arguments["command"] as? String {
            let policy = await commandPolicies.policy(for: serverID)
            switch CommandHardening.policyDecision(command: command, policy: policy) {
            case .forbidden, .denied, .allowed:
                return nil
            case .unspecified:
                break
            }
        }
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

    func commandPolicy(for serverID: UUID) async -> ServerCommandPolicy {
        await commandPolicies.policy(for: serverID)
    }

    /// 保存允许/拒绝列表。返回 false 表示没有写到磁盘，内存保持原样。
    @discardableResult
    func saveCommandPolicy(_ policy: ServerCommandPolicy, forServer serverID: UUID) async -> Bool {
        await commandPolicies.save(policy, for: serverID)
    }

    // MARK: - UI 读/删（非 protocol，供 Trusted Actions 页）
    func allRules(forServer serverID: UUID) async -> [ApprovalRule] {
        (try? await store.fetchApprovalRules(forServer: serverID)) ?? []
    }
    func delete(ruleID: UUID) async {
        try? await store.deleteApprovalRule(ruleID)
    }
}
