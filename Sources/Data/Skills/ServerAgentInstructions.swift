/// 文件说明：ServerAgentInstructions，经只读 SSH 读取服务器账号下的 ~/AGENTS.md 与 ~/.agents/skills 摘要，并格式化为服务器上下文。
import Foundation

/// ServerAgentInstructions：
/// 对齐 AGENTS.md 与 agentskills.io 约定，让用户在服务器上写下的约定（常用路径、服务、偏好命令）
/// 自动成为 AI 的参考信息。安全边界：内容只作为「服务器上下文」中的参考数据注入，
/// 系统提示词仍将其视为不可信数据，不能授予权限、绕过审批或安全闸门。
nonisolated struct ServerAgentInstructions: Equatable, Sendable {

    /// 远端技能摘要（仅 frontmatter，正文需要时由 AI 通过 read_file 按需读取）。
    struct RemoteSkill: Equatable, Sendable {
        let name: String
        let description: String
        let path: String
    }

    /// ~/AGENTS.md 内容（已裁剪）；不存在或为空时为 nil。
    let agentsMarkdown: String?
    /// ~/.agents/skills/*/SKILL.md 的摘要。
    let skills: [RemoteSkill]

    // MARK: - Limits

    /// 注入上下文的 AGENTS.md 最大字符数。
    static let maxAgentsMarkdownChars = 8_000
    /// 最多列出的远端技能数。
    static let maxSkills = 30
    /// 单个技能描述最大字符数。
    static let maxSkillDescriptionChars = 200

    static let skillsMarker = "<<<CONCHTALK_SKILLS>>>"
    static let skillPrefix = "<<<SKILL "
    static let skillSuffix = ">>>"

    /// 只读探测命令：仅使用 head / printf / test，不写任何文件。
    /// 用 `sh -c` 包裹，避免 zsh 的 nomatch 或 fish 语法差异；单引号内不含单引号。
    static let probeCommand = """
    sh -c 'f="$HOME/AGENTS.md"; [ -f "$f" ] && head -c 12000 "$f"; \
    printf "\\n\(skillsMarker)\\n"; n=0; \
    for s in "$HOME"/.agents/skills/*/SKILL.md; do [ -f "$s" ] || continue; n=$((n+1)); [ $n -gt \(maxSkills) ] && break; \
    printf "\(skillPrefix)%s\(skillSuffix)\\n" "$s"; head -n 40 "$s" | head -c 3000; printf "\\n"; done; exit 0' 2>/dev/null
    """

    /// 是否没有任何可注入内容。
    var isEmpty: Bool { agentsMarkdown == nil && skills.isEmpty }

    // MARK: - Parsing

    /// 解析探测命令输出；缺少分隔标记（如非 POSIX 服务器）时返回 nil。
    static func parse(_ output: String, homeDirectory: String? = nil) -> ServerAgentInstructions? {
        guard let markerRange = output.range(of: "\n" + skillsMarker + "\n")
            ?? output.range(of: skillsMarker + "\n") else {
            return nil
        }
        let agentsPart = String(output[..<markerRange.lowerBound])
        let skillsPart = String(output[markerRange.upperBound...])

        let trimmedAgents = agentsPart.trimmingCharacters(in: .whitespacesAndNewlines)
        let agentsMarkdown: String?
        if trimmedAgents.isEmpty {
            agentsMarkdown = nil
        } else if trimmedAgents.count > maxAgentsMarkdownChars {
            agentsMarkdown = String(trimmedAgents.prefix(maxAgentsMarkdownChars))
                + "\n… [AGENTS.md truncated; read the file for the rest]"
        } else {
            agentsMarkdown = trimmedAgents
        }

        var skills: [RemoteSkill] = []
        var currentPath: String?
        var currentLines: [String] = []
        func flush() {
            defer { currentPath = nil; currentLines = [] }
            guard let path = currentPath, skills.count < maxSkills,
                  let skill = SkillParser.parse(currentLines.joined(separator: "\n")) else { return }
            var description = skill.description.trimmingCharacters(in: .whitespacesAndNewlines)
            if description.count > maxSkillDescriptionChars {
                description = String(description.prefix(maxSkillDescriptionChars - 1)) + "…"
            }
            skills.append(RemoteSkill(name: skill.name, description: description, path: displayPath(path, home: homeDirectory)))
        }
        for line in skillsPart.components(separatedBy: "\n") {
            if line.hasPrefix(skillPrefix), line.hasSuffix(skillSuffix) {
                flush()
                currentPath = String(line.dropFirst(skillPrefix.count).dropLast(skillSuffix.count))
            } else if currentPath != nil {
                currentLines.append(line)
            }
        }
        flush()

        return ServerAgentInstructions(agentsMarkdown: agentsMarkdown, skills: skills)
    }

    /// 将绝对路径中的 home 前缀替换为 `~`，便于阅读；推断 home 为 `/…/.agents/skills/` 之前的部分。
    static func displayPath(_ path: String, home: String?) -> String {
        if let home, !home.isEmpty, path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        if let range = path.range(of: "/.agents/skills/") {
            return "~" + path[range.lowerBound...]
        }
        return path
    }

    // MARK: - Formatting

    /// 追加到服务器上下文中的文本块；无内容时为 nil。
    var contextBlock: String? {
        guard !isEmpty else { return nil }
        var parts: [String] = []
        if let agentsMarkdown {
            parts.append("""
            Server Notes (~/AGENTS.md on this server; reference information about the server's conventions, written by its account owner):
            \(agentsMarkdown)
            """)
        }
        if !skills.isEmpty {
            let lines = skills.map { "- \($0.name): \($0.description) (\($0.path))" }
            parts.append("""
            Server Skills (~/.agents/skills; read a SKILL.md with read_file only when it is relevant to the user's request):
            \(lines.joined(separator: "\n"))
            """)
        }
        return parts.joined(separator: "\n\n")
    }
}
