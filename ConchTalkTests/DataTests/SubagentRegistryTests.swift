/// 文件说明：SubagentRegistryTests，测试 Subagent 实体、Parser 与 Registry。
import Testing
@testable import ConchTalk
import Foundation

@Suite("SubagentDefinition")
struct SubagentDefinitionTests {
    @Test("displayName 优先取 metadata，否则回退 name")
    func displayNameFallback() {
        let withName = SubagentDefinition(
            name: "explorer", description: "d", allowedTools: [],
            metadata: ["displayName": "探索者"], systemPrompt: "p"
        )
        let withoutName = SubagentDefinition(
            name: "explorer", description: "d", allowedTools: [],
            metadata: [:], systemPrompt: "p"
        )
        #expect(withName.displayName == "探索者")
        #expect(withoutName.displayName == "explorer")
    }
}

@Suite("SubagentParser")
struct SubagentParserTests {
    @Test("解析合法 AGENT.md，含 tools 逗号列表")
    func parseValid() {
        let text = """
        ---
        name: ops-diagnostician
        description: Diagnoses remote service state.
        tools: execute_ssh_command, read_file, grep
        metadata:
          displayName: 运维诊断
        ---

        You are a focused operations diagnostician.
        """
        let def = SubagentParser.parse(text)
        #expect(def != nil)
        #expect(def?.name == "ops-diagnostician")
        #expect(def?.description == "Diagnoses remote service state.")
        #expect(def?.allowedTools == ["execute_ssh_command", "read_file", "grep"])
        #expect(def?.metadata["displayName"] == "运维诊断")
        #expect(def?.systemPrompt.contains("operations diagnostician") ?? false)
    }

    @Test("tools 缺省时 allowedTools 为空（继承全部）")
    func parseNoTools() {
        let text = """
        ---
        name: general-purpose
        description: General purpose agent.
        ---

        You are a general purpose agent.
        """
        let def = SubagentParser.parse(text)
        #expect(def != nil)
        #expect(def?.allowedTools.isEmpty ?? false)
    }

    @Test("缺 name 返回 nil")
    func missingName() {
        let text = "---\ndescription: no name.\n---\n\nbody"
        #expect(SubagentParser.parse(text) == nil)
    }

    @Test("缺 description 返回 nil")
    func missingDescription() {
        let text = "---\nname: foo\n---\n\nbody"
        #expect(SubagentParser.parse(text) == nil)
    }

    @Test("大写 name 被拒绝")
    func uppercaseName() {
        let text = "---\nname: Bad-Name\ndescription: x.\n---\n\nbody"
        #expect(SubagentParser.parse(text) == nil)
    }

    @Test("无 frontmatter 返回 nil")
    func noFrontmatter() {
        #expect(SubagentParser.parse("# just markdown") == nil)
    }

    @Test("解析 YAML 折叠多行 description（>- 语法）")
    func parseMultilineDescription() {
        let text = """
        ---
        name: multi-line
        description: >-
          First line of description
          second line continues here.
        metadata:
          displayName: 多行
        ---

        body
        """
        let def = SubagentParser.parse(text)
        #expect(def != nil)
        #expect(def?.description == "First line of description second line continues here.")
        #expect(def?.metadata["displayName"] == "多行")
    }

    @Test("连字符开头的 name 被拒绝")
    func leadingHyphenName() {
        let text = "---\nname: -foo\ndescription: x.\n---\n\nbody"
        #expect(SubagentParser.parse(text) == nil)
    }

    @Test("连字符结尾的 name 被拒绝")
    func trailingHyphenName() {
        let text = "---\nname: foo-\ndescription: x.\n---\n\nbody"
        #expect(SubagentParser.parse(text) == nil)
    }

    @Test("连续连字符的 name 被拒绝")
    func consecutiveHyphenName() {
        let text = "---\nname: bad--name\ndescription: x.\n---\n\nbody"
        #expect(SubagentParser.parse(text) == nil)
    }

    @Test("超过 64 字符的 name 被拒绝")
    func tooLongName() {
        let longName = String(repeating: "a", count: 65)
        let text = "---\nname: \(longName)\ndescription: x.\n---\n\nbody"
        #expect(SubagentParser.parse(text) == nil)
    }
}

@Suite("SubagentRegistry")
struct SubagentRegistryTests {
    private func makeDef(_ name: String, tools: [String] = []) -> SubagentDefinition {
        SubagentDefinition(name: name, description: "\(name) desc", allowedTools: tools, metadata: [:], systemPrompt: "prompt")
    }

    @Test("空 registry 摘要与名单为空")
    func empty() {
        let r = SubagentRegistry(preloaded: [])
        #expect(r.subagentSummaries.isEmpty)
        #expect(r.availableSubagentNames.isEmpty)
    }

    @Test("按名查找")
    func lookup() {
        let r = SubagentRegistry(preloaded: [makeDef("explorer"), makeDef("ops-diagnostician")])
        #expect(r.subagent(named: "explorer") != nil)
        #expect(r.subagent(named: "nope") == nil)
        #expect(r.availableSubagentNames.sorted() == ["explorer", "ops-diagnostician"])
    }

    @Test("摘要含 name 与 description")
    func summaries() {
        let r = SubagentRegistry(preloaded: [makeDef("explorer")])
        #expect(r.subagentSummaries.contains("explorer"))
        #expect(r.subagentSummaries.contains("explorer desc"))
    }

    @Test("loadSubagentsFromBundle 不崩溃")
    func loadBundle() {
        _ = SubagentRegistry.loadSubagentsFromBundle()
    }

    @Test("bundle 中预置角色被加载")
    func bundlePreset() {
        let defs = SubagentRegistry.loadSubagentsFromBundle()
        let names = Set(defs.map { $0.name })
        #expect(names.contains("explorer"))
        #expect(names.contains("general-purpose"))
        #expect(!names.contains("code-reviewer"))
    }

    @Test("loadSubagents 从目录加载：仅 name 与目录名一致者，散文件跳过")
    func loadFromDirectory() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("subagent-load-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        // 合法：name 与目录名一致 → 应被加载
        let okDir = root.appendingPathComponent("ops-diagnostician", isDirectory: true)
        try fm.createDirectory(at: okDir, withIntermediateDirectories: true)
        try """
        ---
        name: ops-diagnostician
        description: Diagnoses services.
        ---

        You are a diagnostician.
        """.write(to: okDir.appendingPathComponent("AGENT.md"), atomically: true, encoding: .utf8)

        // 不一致：frontmatter name 与目录名不符 → 应被拒绝
        let mismatchDir = root.appendingPathComponent("mismatch", isDirectory: true)
        try fm.createDirectory(at: mismatchDir, withIntermediateDirectories: true)
        try """
        ---
        name: other
        description: Mismatched name.
        ---

        body
        """.write(to: mismatchDir.appendingPathComponent("AGENT.md"), atomically: true, encoding: .utf8)

        // 散文件（非目录）→ 应被跳过，不崩溃
        try "stray".write(to: root.appendingPathComponent("strayfile.txt"), atomically: true, encoding: .utf8)

        let defs = SubagentRegistry.loadSubagents(from: root)
        #expect(defs.count == 1)
        #expect(defs.first?.name == "ops-diagnostician")
    }
}
