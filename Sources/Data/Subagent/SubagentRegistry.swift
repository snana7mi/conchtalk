/// 文件说明：SubagentRegistry，管理 subagent 角色的加载与查找。
import Foundation

/// SubagentRegistry：
/// 从 bundle 的 Subagents 文件夹加载角色（目录结构 <name>/AGENT.md），不可变、线程安全。
nonisolated final class SubagentRegistry: Sendable {
    private let definitions: [SubagentDefinition]
    private let map: [String: SubagentDefinition]

    init(preloaded: [SubagentDefinition] = []) {
        self.definitions = preloaded
        var m: [String: SubagentDefinition] = [:]
        for d in preloaded { m[d.name] = d }
        self.map = m
    }

    static func loadSubagentsFromBundle() -> [SubagentDefinition] {
        guard let url = Bundle.main.url(forResource: "Subagents", withExtension: nil) else {
            return []
        }
        return loadSubagents(from: url)
    }

    static func loadSubagents(from directoryURL: URL) -> [SubagentDefinition] {
        var loaded: [SubagentDefinition] = []
        guard let subdirs = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        for subdir in subdirs {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: subdir.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let file = subdir.appendingPathComponent("AGENT.md")
            guard let text = try? String(contentsOf: file, encoding: .utf8),
                  let def = SubagentParser.parse(text),
                  def.name == subdir.lastPathComponent else { continue }
            loaded.append(def)
        }
        return loaded
    }

    func subagent(named name: String) -> SubagentDefinition? { map[name] }

    var availableSubagentNames: [String] { definitions.map { $0.name } }

    /// 用于注入主 system prompt，供 AI 判断分派对象。
    var subagentSummaries: String {
        guard !definitions.isEmpty else { return "" }
        return definitions.map { "- \($0.name): \($0.description)" }.joined(separator: "\n")
    }
}
