/// 文件说明：SkillRegistryTests，测试 SkillRegistry 和 SkillParser 的加载与查找行为。
import Testing
@testable import ConchTalk
import Foundation

@Suite("SkillRegistry")
struct SkillRegistryTests {

    @Test("空预加载列表创建空 registry")
    func emptyPreload() {
        let registry = SkillRegistry(preloaded: [])
        #expect(registry.skillSummaries.isEmpty)
        #expect(registry.availableSkillNames.isEmpty)
    }

    @Test("预加载的 skills 可通过名称查找")
    func preloadedSkillsLookup() {
        let skill = Skill(
            name: "test-skill",
            description: "A test skill for unit testing",
            compatibility: nil,
            metadata: ["author": "test"],
            content: "# Test\nDo the thing.",
            directoryURL: nil
        )
        let registry = SkillRegistry(preloaded: [skill])

        #expect(registry.skill(named: "test-skill") != nil)
        #expect(registry.skill(named: "nonexistent") == nil)
        #expect(registry.availableSkillNames == ["test-skill"])
    }

    @Test("skillSummaries 只包含名称和描述")
    func summariesContent() {
        let skill = Skill(
            name: "health-check",
            description: "Check server health",
            compatibility: nil,
            metadata: ["displayName": "Health Check"],
            content: "# Health Check",
            directoryURL: nil
        )
        let registry = SkillRegistry(preloaded: [skill])
        let summaries = registry.skillSummaries

        #expect(summaries.contains("health-check"))
        #expect(summaries.contains("Check server health"))
        #expect(!summaries.contains("Health Check"), "displayName 不应出现在精简摘要中")
    }

    @Test("displayName 优先取 metadata，否则回退 name")
    func displayNameFallback() {
        let withDisplayName = Skill(
            name: "my-skill",
            description: "desc",
            compatibility: nil,
            metadata: ["displayName": "My Skill"],
            content: "",
            directoryURL: nil
        )
        let withoutDisplayName = Skill(
            name: "my-skill",
            description: "desc",
            compatibility: nil,
            metadata: [:],
            content: "",
            directoryURL: nil
        )

        #expect(withDisplayName.displayName == "My Skill")
        #expect(withoutDisplayName.displayName == "my-skill")
    }

    @Test("readReference 拒绝目录穿越路径")
    func readReferenceRejectsTraversal() {
        let dirURL = URL(fileURLWithPath: "/tmp/skills/test-skill")
        let skill = Skill(
            name: "test-skill",
            description: "desc",
            compatibility: nil,
            metadata: [:],
            content: "",
            directoryURL: dirURL
        )
        let registry = SkillRegistry(preloaded: [skill])

        // ../ 穿越应返回 nil
        #expect(registry.readReference(relativePath: "../../../etc/passwd", forSkill: "test-skill") == nil)
        #expect(registry.readReference(relativePath: "references/../../secret.txt", forSkill: "test-skill") == nil)
        // 兄弟目录穿越（test-skill-evil）也应被拒绝
        #expect(registry.readReference(relativePath: "../test-skill-evil/secret.txt", forSkill: "test-skill") == nil)
    }

    @Test("loadSkillsFromBundle 不会崩溃")
    func loadFromBundleDoesNotCrash() {
        let skills = SkillRegistry.loadSkillsFromBundle()
        _ = skills
    }
}

@Suite("SkillParser")
struct SkillParserTests {

    @Test("解析符合规范的 SKILL.md")
    func parseValidSkill() {
        let text = """
        ---
        name: test-skill
        description: A test skill for parsing validation.
        compatibility: Requires Python 3.14+
        metadata:
          author: conchtalk
          version: "1.0"
          displayName: Test Skill
        ---

        # Test Skill

        Do the thing step by step.
        """
        let skill = SkillParser.parse(text)

        #expect(skill != nil)
        #expect(skill?.name == "test-skill")
        #expect(skill?.description == "A test skill for parsing validation.")
        #expect(skill?.compatibility == "Requires Python 3.14+")
        #expect(skill?.metadata["author"] == "conchtalk")
        #expect(skill?.metadata["version"] == "1.0")
        #expect(skill?.metadata["displayName"] == "Test Skill")
        #expect(skill?.displayName == "Test Skill")
        #expect(skill?.content.contains("# Test Skill") ?? false)
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
          author: test
        ---

        # Content
        """
        let skill = SkillParser.parse(text)

        #expect(skill != nil)
        #expect(skill?.description == "First line of description second line continues here.")
    }

    @Test("缺少 name 字段时返回 nil")
    func missingNameReturnsNil() {
        let text = """
        ---
        description: A skill without a name.
        ---

        # No Name
        """
        #expect(SkillParser.parse(text) == nil)
    }

    @Test("缺少 description 字段时返回 nil")
    func missingDescriptionReturnsNil() {
        let text = """
        ---
        name: no-desc
        ---

        # No Description
        """
        #expect(SkillParser.parse(text) == nil)
    }

    @Test("name 格式校验：大写字母被拒绝")
    func uppercaseNameRejected() {
        let text = """
        ---
        name: Invalid-Name
        description: Has uppercase.
        ---

        # Content
        """
        #expect(SkillParser.parse(text) == nil)
    }

    @Test("name 格式校验：连字符开头被拒绝")
    func leadingHyphenRejected() {
        let text = """
        ---
        name: -invalid
        description: Leading hyphen.
        ---

        # Content
        """
        #expect(SkillParser.parse(text) == nil)
    }

    @Test("name 格式校验：连续连字符被拒绝")
    func consecutiveHyphensRejected() {
        let text = """
        ---
        name: bad--name
        description: Consecutive hyphens.
        ---

        # Content
        """
        #expect(SkillParser.parse(text) == nil)
    }

    @Test("无 frontmatter 返回 nil")
    func noFrontmatterReturnsNil() {
        let text = "# Just a markdown file\nNo frontmatter here."
        #expect(SkillParser.parse(text) == nil)
    }

    @Test("可选字段缺失不影响解析")
    func optionalFieldsMissing() {
        let text = """
        ---
        name: minimal
        description: Just name and description.
        ---

        # Minimal
        """
        let skill = SkillParser.parse(text)

        #expect(skill != nil)
        #expect(skill?.compatibility == nil)
        #expect(skill?.metadata.isEmpty ?? false)
    }

    @Test("directoryURL 正确传递")
    func directoryURLPassthrough() {
        let text = """
        ---
        name: with-dir
        description: Has directory URL.
        ---

        # Content
        """
        let url = URL(fileURLWithPath: "/tmp/skills/with-dir")
        let skill = SkillParser.parse(text, directoryURL: url)

        #expect(skill?.directoryURL == url)
    }
}
