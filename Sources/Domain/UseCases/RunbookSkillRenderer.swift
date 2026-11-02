/// 文件说明：RunbookSkillRenderer，把操作手册渲染成 Skill，并生成再次运行的提示词。
import Foundation

/// RunbookSkillRenderer：
/// 用户手册与内置 Skill 使用同一份 SKILL.md 格式，方便 `activate_skill` 加载。
nonisolated enum RunbookSkillRenderer {
    /// 生成合法的 Skill 名称。避开已占用名称，且只含 ASCII 小写、数字和连字符。
    static func slug(displayName: String, reserved: Set<String>, id: UUID) -> String {
        let ascii = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789")
        var slug = ""
        var previousHyphen = false
        for scalar in displayName.lowercased().unicodeScalars {
            if ascii.contains(scalar) {
                slug.unicodeScalars.append(scalar)
                previousHyphen = false
            } else if !slug.isEmpty && !previousHyphen {
                slug.append("-")
                previousHyphen = true
            }
        }
        while slug.hasSuffix("-") { slug.removeLast() }
        if slug.count > 48 {
            slug = String(slug.prefix(48))
            while slug.hasSuffix("-") { slug.removeLast() }
        }
        if slug.isEmpty {
            slug = "runbook-\(id.uuidString.prefix(8).lowercased())"
        }

        var candidate = slug
        var suffix = 2
        while reserved.contains(candidate) {
            let tail = "-\(suffix)"
            let room = max(1, 64 - tail.count)
            candidate = String(slug.prefix(room)) + tail
            while candidate.contains("--") {
                candidate = candidate.replacingOccurrences(of: "--", with: "-")
            }
            suffix += 1
            if suffix > 500 {
                candidate = "runbook-\(id.uuidString.prefix(8).lowercased())-\(suffix)"
                break
            }
        }
        return String(candidate.prefix(64))
    }

    /// 由显示名和过程正文生成完整手册。名称非法或正文无法解析为 Skill 时返回失败。
    static func make(
        displayName: String,
        messages: [Message],
        reservedNames: Set<String>,
        sourceServerID: UUID?,
        id: UUID = UUID(),
        now: Date = Date()
    ) -> Result<Runbook, RunbookSaveFailure> {
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return .failure(.emptyName) }
        switch RunbookExtractor.extract(messages: messages) {
        case .failure(let reason):
            return .failure(.extraction(reason))
        case .success(let draft):
            let name = slug(displayName: trimmedName, reserved: reservedNames, id: id)
            let description = skillDescription(displayName: trimmedName)
            let markdown = skillMarkdown(name: name, displayName: trimmedName, description: description, prompt: draft.prompt)
            return .success(Runbook(
                id: id,
                name: name,
                displayName: String(trimmedName.prefix(80)),
                description: description,
                prompt: draft.prompt,
                skillMarkdown: markdown,
                createdAt: now,
                modifiedAt: now,
                sourceServerID: sourceServerID
            ))
        }
    }

    /// 再次运行时发给当前会话的用户消息。过程写在消息里，因此直连代理模式也能执行。
    static func replayPrompt(for runbook: Runbook) -> String {
        """
        Run the saved runbook "\(runbook.displayName)" (skill: \(runbook.name)).
        Activate that skill if it is listed, then follow the procedure on this server.
        Report results in the user's language and wait for confirmation before any change.

        \(runbook.prompt)
        """
    }

    private static func skillDescription(displayName: String) -> String {
        let safe = displayName.replacingOccurrences(of: "\"", with: "'").replacingOccurrences(of: "\n", with: " ")
        let text = "User-saved runbook \"\(safe)\". Use when the user asks to rerun this procedure or names this runbook."
        return String(text.prefix(1_024))
    }

    private static func skillMarkdown(name: String, displayName: String, description: String, prompt: String) -> String {
        let quotedDescription = yamlQuoted(description)
        let quotedTitle = yamlQuoted(displayName)
        return """
        ---
        name: \(name)
        description: \(quotedDescription)
        metadata:
          author: conchtalk-user
          displayName: \(quotedTitle)
          kind: runbook
        ---

        # \(displayName)

        This runbook was saved from a successful conversation. Follow the procedure on the current server.

        Report progress in the user's language. After each stage, report results and wait for confirmation before continuing. If a step fails, stop and explain the failure in the user's language.

        \(prompt)
        """
    }

    /// YAML 双引号标量。解析器只去掉首尾引号，因此内部引号先换成撇号。
    private static func yamlQuoted(_ value: String) -> String {
        let cleaned = value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\\", with: "")
            .replacingOccurrences(of: "\"", with: "'")
        return "\"\(cleaned)\""
    }
}
