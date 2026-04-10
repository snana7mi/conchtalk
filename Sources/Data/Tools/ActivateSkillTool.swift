/// 文件说明：ActivateSkillTool，AI 用于获取策略编排 Skill 内容的工具。
import Foundation

/// ActivateSkillTool：
/// 纯客户端工具，不走 SSH。AI 调用此工具获取 Skill 的完整内容，
/// 内容作为 tool result 返回，留在对话历史中供后续轮次参考。
/// 支持按需加载 skill 目录下的辅助文件（references/ 等）。
nonisolated final class ActivateSkillTool: ToolProtocol, @unchecked Sendable {
    let name = "activate_skill"
    let description = """
        Load a strategy skill to guide multi-step task execution. \
        Call this when the user's request matches a known skill. \
        Returns the skill's full guidance content. \
        To load a reference file from the skill, pass the relative path in reference_path.
        """

    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "skill_name": [
                "type": "string",
                "description": "The name of the skill to load",
            ] as [String: String],
            "explanation": [
                "type": "string",
                "description": "A brief explanation of why you are loading this skill",
            ] as [String: String],
            "reference_path": [
                "type": "string",
                "description": "Optional relative path to a reference file within the skill directory (e.g. references/providers.md)",
            ] as [String: String],
        ] as [String: Any],
        "required": ["skill_name", "explanation"],
    ]

    private let skillRegistry: SkillRegistry

    init(skillRegistry: SkillRegistry) {
        self.skillRegistry = skillRegistry
    }

    func validateSafety(arguments: [String: Any]) -> SafetyLevel {
        .safe
    }

    func execute(arguments: [String: Any], sshClient: SSHClientProtocol) async throws -> ToolExecutionResult {
        guard let skillName = arguments["skill_name"] as? String else {
            let available = skillRegistry.availableSkillNames.joined(separator: ", ")
            return ToolExecutionResult(
                output: "ERROR: skill_name is required. Available skills: \(available)",
                isSuccess: false
            )
        }

        // 按需加载辅助文件
        if let referencePath = arguments["reference_path"] as? String, !referencePath.isEmpty {
            guard let content = skillRegistry.readReference(relativePath: referencePath, forSkill: skillName) else {
                return ToolExecutionResult(
                    output: "ERROR: Reference file '\(referencePath)' not found in skill '\(skillName)'.",
                    isSuccess: false
                )
            }
            return ToolExecutionResult(output: content)
        }

        // 加载 skill 主体内容
        guard let skill = skillRegistry.skill(named: skillName) else {
            let available = skillRegistry.availableSkillNames.joined(separator: ", ")
            return ToolExecutionResult(
                output: "ERROR: Skill '\(skillName)' not found. Available skills: \(available)",
                isSuccess: false
            )
        }

        return ToolExecutionResult(output: skill.content)
    }
}
