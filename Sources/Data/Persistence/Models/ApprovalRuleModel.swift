/// 文件说明：ApprovalRuleModel，授权规则的 SwiftData 持久化模型（含同步簿记字段）。
import Foundation
import SwiftData

/// ApprovalRuleModel：镜像 MemoryEntryModel 的 syncable 模式。
/// matcher 拆为可存储字段：matcherKind + tokensJSON / pathPrefix + recursive。
@Model
final class ApprovalRuleModel {
    @Attribute(.unique) var id: UUID
    var serverID: UUID
    var toolName: String
    var matcherKind: String        // "commandPrefix" | "pathPrefix"
    var tokensJSON: String?        // commandPrefix: JSON([String])
    var pathPrefix: String?        // pathPrefix: 规范化前缀
    var recursive: Bool
    var displayLabel: String
    var createdAt: Date
    // 同步簿记
    var syncVersion: Int64 = 0
    var modifiedAt: Date = Date()
    var isDeleted: Bool = false
    var isRemoteMerge: Bool = false

    init(id: UUID, serverID: UUID, toolName: String, matcherKind: String,
         tokensJSON: String?, pathPrefix: String?, recursive: Bool,
         displayLabel: String, createdAt: Date) {
        self.id = id
        self.serverID = serverID
        self.toolName = toolName
        self.matcherKind = matcherKind
        self.tokensJSON = tokensJSON
        self.pathPrefix = pathPrefix
        self.recursive = recursive
        self.displayLabel = displayLabel
        self.createdAt = createdAt
    }

    /// 转 Domain 实体（不含同步簿记字段）。
    func toDomain() -> ApprovalRule? {
        let matcher: ApprovalMatcher
        switch matcherKind {
        case "commandPrefix":
            guard let json = tokensJSON, let data = json.data(using: .utf8),
                  let tokens = try? JSONDecoder().decode([String].self, from: data) else { return nil }
            matcher = .commandPrefix(tokens: tokens)
        case "pathPrefix":
            guard let p = pathPrefix else { return nil }
            matcher = .pathPrefix(prefix: p, recursive: recursive)
        default:
            return nil
        }
        return ApprovalRule(id: id, serverID: serverID, toolName: toolName,
                            matcher: matcher, displayLabel: displayLabel,
                            createdAt: createdAt, modifiedAt: modifiedAt)
    }

    /// 从 Domain 构造（不含同步簿记）。
    static func fromDomain(_ rule: ApprovalRule) -> ApprovalRuleModel {
        var kind = "pathPrefix"
        var tokensJSON: String?
        var pathPrefix: String?
        var recursive = false
        switch rule.matcher {
        case .commandPrefix(let tokens):
            kind = "commandPrefix"
            tokensJSON = String(data: (try? JSONEncoder().encode(tokens)) ?? Data(), encoding: .utf8)
        case .pathPrefix(let prefix, let rec):
            kind = "pathPrefix"
            pathPrefix = prefix
            recursive = rec
        }
        return ApprovalRuleModel(id: rule.id, serverID: rule.serverID, toolName: rule.toolName,
                                 matcherKind: kind, tokensJSON: tokensJSON, pathPrefix: pathPrefix,
                                 recursive: recursive, displayLabel: rule.displayLabel, createdAt: rule.createdAt)
    }
}
