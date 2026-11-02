/// 文件说明：SkillLookingUp，Skill 查询契约，供内置技能与用户操作手册共用。
import Foundation

/// SkillLookingUp：
/// 按名称查找 Skill、生成系统提示摘要，并按需读取辅助文件。
/// 内置 `SkillRegistry` 与可更新的用户手册层都实现该契约。
nonisolated protocol SkillLookingUp: Sendable {
    /// 按名称查找 Skill。内置技能优先于同名用户手册。
    func skill(named name: String) -> Skill?

    /// 注入系统提示的名称与描述摘要。
    var skillSummaries: String { get }

    /// 当前可见的 Skill 名称，用于错误提示。
    var availableSkillNames: [String] { get }

    /// 读取 Skill 目录内的辅助文件。用户手册没有目录时返回 nil。
    func readReference(relativePath: String, forSkill skillName: String) -> String?
}
