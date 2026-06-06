/// 文件说明：SubagentDefinition，subagent 角色定义的领域实体。
import Foundation

/// SubagentDefinition：
/// 一个 subagent 角色的定义，来源于 Subagents/<name>/AGENT.md。
nonisolated struct SubagentDefinition: Sendable {
    /// 唯一标识，小写字母+连字符，匹配目录名。
    let name: String
    /// 角色用途说明，供主 AI 判断何时分派（英文，对 AI）。
    let description: String
    /// 允许使用的工具名白名单；空数组表示继承父全部工具。
    let allowedTools: [String]
    /// 任意键值元数据（如 displayName）。
    let metadata: [String: String]
    /// 角色 system prompt（= AGENT.md body）。
    let systemPrompt: String

    /// 用户可见显示名，优先 metadata["displayName"]，否则回退 name。
    var displayName: String { metadata["displayName"] ?? name }
}
