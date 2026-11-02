/// 文件说明：MutableSkillLookup，在内置 Skill 之上叠加用户操作手册。
import Foundation

/// MutableSkillLookup：
/// 内置技能优先。同名用户手册不会盖住包内 Skill。
/// 手册增删后调用 `replaceExtras`，后续模型请求会读到新的摘要。
nonisolated final class MutableSkillLookup: SkillLookingUp, @unchecked Sendable {
    private let lock = NSLock()
    private let base: SkillRegistry
    private var extras: [Skill]

    init(base: SkillRegistry, extras: [Skill] = []) {
        self.base = base
        self.extras = extras
    }

    func replaceExtras(_ skills: [Skill]) {
        lock.lock()
        extras = skills
        lock.unlock()
    }

    func bundleSkillNames() -> [String] {
        base.availableSkillNames
    }

    func skill(named name: String) -> Skill? {
        if let builtin = base.skill(named: name) {
            return builtin
        }
        lock.lock()
        defer { lock.unlock() }
        return extras.first { $0.name == name }
    }

    var skillSummaries: String {
        let extraLines = visibleExtras().map { "- \($0.name): \($0.description)" }
        let builtin = base.skillSummaries
        if builtin.isEmpty { return extraLines.joined(separator: "\n") }
        if extraLines.isEmpty { return builtin }
        return builtin + "\n" + extraLines.joined(separator: "\n")
    }

    var availableSkillNames: [String] {
        var names = base.availableSkillNames
        let taken = Set(names)
        for skill in visibleExtras() where !taken.contains(skill.name) {
            names.append(skill.name)
        }
        return names
    }

    func readReference(relativePath: String, forSkill skillName: String) -> String? {
        base.readReference(relativePath: relativePath, forSkill: skillName)
    }

    private func visibleExtras() -> [Skill] {
        lock.lock()
        defer { lock.unlock() }
        let taken = Set(base.availableSkillNames)
        return extras.filter { !taken.contains($0.name) }
    }
}

/// RunbookSkills：把未删除手册解析成可叠加的 Skill。
nonisolated enum RunbookSkills {
    static func skills(from runbooks: [Runbook]) -> [Skill] {
        runbooks.compactMap { runbook in
            guard !runbook.isDeleted else { return nil }
            return SkillParser.parse(runbook.skillMarkdown)
        }
    }
}

/// RunbookCatalog：手册存储与 Skill 叠加层的组合，保存或删除后刷新模型可见技能。
nonisolated final class RunbookCatalog: @unchecked Sendable {
    let store: FileRunbookStore
    let skills: MutableSkillLookup

    init(store: FileRunbookStore, skills: MutableSkillLookup) {
        self.store = store
        self.skills = skills
    }

    func reload() {
        let runbooks = (try? store.loadAll()) ?? []
        skills.replaceExtras(RunbookSkills.skills(from: runbooks))
    }

    /// 保存成功后刷新 Skill 层。
    func save(_ runbook: Runbook) throws {
        try store.save(runbook)
        reload()
    }

    func softDelete(id: UUID, now: Date = Date()) throws {
        try store.softDelete(id: id, now: now)
        reload()
    }
}
