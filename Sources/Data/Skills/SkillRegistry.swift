/// 文件说明：SkillRegistry，管理 Skill 的加载与查找，遵循 agentskills.io 目录规范。
import Foundation

/// SkillRegistry：
/// 从 bundle 中的 Skills 文件夹加载 skill（目录结构：skill-name/SKILL.md）。
/// 支持按需读取 skill 目录下的辅助文件（references/ 等）。
/// 初始化后状态不可变，天然线程安���。
nonisolated final class SkillRegistry: Sendable {
    /// 所有已加载的 skill
    private let skills: [Skill]
    /// skill name 索引
    private let skillMap: [String: Skill]

    /// 使用预加载的 skills 初始化（配合 async 工厂方法，避免在主线程做文件 I/O）。
    init(preloaded: [Skill] = []) {
        self.skills = preloaded
        var map: [String: Skill] = [:]
        for skill in preloaded {
            map[skill.name] = skill
        }
        self.skillMap = map
    }

    /// 从 bundle 的 Skills 文件夹加载所有 skill（目录结构：skill-name/SKILL.md）。
    /// Skills 文件夹作为 folder reference 打包，保留子目录结构。
    static func loadSkillsFromBundle() -> [Skill] {
        guard let skillsURL = Bundle.main.url(forResource: "Skills", withExtension: nil) else {
            return []
        }
        return loadSkills(from: skillsURL)
    }

    /// 从指定目录加载所有 skill（便于测试和自定义路径）。
    static func loadSkills(from directoryURL: URL) -> [Skill] {
        var loaded: [Skill] = []
        guard let subdirectories = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        for subdir in subdirectories {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: subdir.path, isDirectory: &isDir),
                  isDir.boolValue else {
                continue
            }

            let skillFile = subdir.appendingPathComponent("SKILL.md")
            guard let text = try? String(contentsOf: skillFile, encoding: .utf8),
                  let skill = SkillParser.parse(text, directoryURL: subdir) else {
                continue
            }

            // 校验 name 与目录名一致
            if skill.name == subdir.lastPathComponent {
                loaded.append(skill)
            }
        }

        return loaded
    }

    /// 返回所有 skill 的摘要（name + description），用于注入 system prompt。
    var skillSummaries: String {
        guard !skills.isEmpty else { return "" }
        return skills.map { "- \($0.name): \($0.description)" }
            .joined(separator: "\n")
    }

    /// 按名查找 skill。
    func skill(named name: String) -> Skill? {
        skillMap[name]
    }

    /// 读取 skill 目录下的辅助文件（如 references/providers.md）。
    /// 会校验解析后的路径不逃逸出 skill 目录，防止目录穿越攻击。
    /// - Parameters:
    ///   - relativePath: 相对于 skill 目录的路径
    ///   - skillName: skill 名称
    /// - Returns: 文件内容，路���非法或文件不存在返回 nil
    func readReference(relativePath: String, forSkill skillName: String) -> String? {
        guard let skill = skillMap[skillName],
              let dirURL = skill.directoryURL else {
            return nil
        }
        let fileURL = dirURL.appendingPathComponent(relativePath).standardizedFileURL
        // resolvingSymlinksInPath 解析符号链接后得到真实路径，防止 symlink 逃逸
        let resolvedFile = fileURL.resolvingSymlinksInPath().path
        let resolvedDir = dirURL.standardizedFileURL.resolvingSymlinksInPath().path
        // 尾部加 "/" 确保按目录边界匹配，防止兄弟目录名前缀碰撞
        let dirPrefix = resolvedDir.hasSuffix("/") ? resolvedDir : resolvedDir + "/"
        // 校验真实路径仍在 skill 目录内（防止穿越、兄弟目录、符号链接逃逸）
        guard resolvedFile.hasPrefix(dirPrefix) else {
            return nil
        }
        return try? String(contentsOf: fileURL, encoding: .utf8)
    }

    /// 返回所有可用 skill 的名称列表（用于错误提���）。
    var availableSkillNames: [String] {
        skills.map { $0.name }
    }
}
