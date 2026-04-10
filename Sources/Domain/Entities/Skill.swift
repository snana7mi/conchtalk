/// 文件说明：Skill，策略编排模板的领域实体，遵循 agentskills.io 规范。
import Foundation

/// Skill：
/// 表示一个可激活的策略编排模板，包含元数据和 Markdown 内容。
/// AI 激活后，content 被注入 system prompt 引导分阶段执行。
/// frontmatter 字段对齐 agentskills.io 规范。
struct Skill: Sendable {
    /// 唯一标识符，小写字母+连字符，如 "health-check"（必须匹配目录名）
    let name: String
    /// 描述 skill 做什么以及何时使用，供 AI 判断是否匹配（必填，最多 1024 字符）
    let description: String
    /// 环境要求说明，如 "Requires sshpass installed on the remote server"（可选）
    let compatibility: String?
    /// 任意键值元数据（可选），如 author、version、displayName
    let metadata: [String: String]
    /// SKILL.md 的 Markdown body，激活后注入 system prompt
    let content: String
    /// skill 所在目录的 URL，用于按需加载 references/ 等辅助文件
    let directoryURL: URL?

    /// 用户可见的显示名称，优先取 metadata["displayName"]，否则回退到 name
    var displayName: String {
        metadata["displayName"] ?? name
    }
}
