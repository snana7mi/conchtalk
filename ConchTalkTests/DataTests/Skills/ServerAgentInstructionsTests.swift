/// 文件说明：ServerAgentInstructionsTests，验证服务器 ~/AGENTS.md 与 ~/.agents/skills 探测输出的解析、裁剪与上下文格式化。
import Foundation
import Testing
@testable import ConchTalk

@Suite("Server AGENTS.md and skills")
struct ServerAgentInstructionsTests {

    /// 与真实 `sh` 运行探测命令得到的输出格式一致（含无 frontmatter 的坏技能）。
    private let sampleOutput = """
    # Notes
    Services live in /srv.

    <<<CONCHTALK_SKILLS>>>
    <<<SKILL /home/lee/.agents/skills/broken/SKILL.md>>>
    no frontmatter

    <<<SKILL /home/lee/.agents/skills/deploy/SKILL.md>>>
    ---
    name: deploy
    description: Deploy the web app with docker compose.
    ---
    # Body
    steps

    """

    @Test("解析 AGENTS.md 与有效技能，跳过无 frontmatter 的技能")
    func parsesNotesAndSkills() throws {
        let parsed = try #require(ServerAgentInstructions.parse(sampleOutput))
        #expect(parsed.agentsMarkdown == "# Notes\nServices live in /srv.")
        #expect(parsed.skills == [
            .init(name: "deploy", description: "Deploy the web app with docker compose.", path: "~/.agents/skills/deploy/SKILL.md"),
        ])
        let block = try #require(parsed.contextBlock)
        #expect(block.contains("Server Notes (~/AGENTS.md"))
        #expect(block.contains("Services live in /srv."))
        #expect(block.contains("- deploy: Deploy the web app with docker compose. (~/.agents/skills/deploy/SKILL.md)"))
    }

    @Test("两者都不存在时为空，不注入上下文")
    func emptyOutput() throws {
        let parsed = try #require(ServerAgentInstructions.parse("\n<<<CONCHTALK_SKILLS>>>\n"))
        #expect(parsed.isEmpty)
        #expect(parsed.contextBlock == nil)
    }

    @Test("缺少分隔标记（非 POSIX shell 或报错）时返回 nil")
    func missingMarker() {
        #expect(ServerAgentInstructions.parse("'sh' is not recognized as an internal or external command") == nil)
        #expect(ServerAgentInstructions.parse("") == nil)
    }

    @Test("只有技能、没有 AGENTS.md 时仅列出技能")
    func skillsOnly() throws {
        let output = "\n<<<CONCHTALK_SKILLS>>>\n<<<SKILL /root/.agents/skills/backup/SKILL.md>>>\n---\nname: backup\ndescription: Back up databases.\n---\n"
        let parsed = try #require(ServerAgentInstructions.parse(output))
        #expect(parsed.agentsMarkdown == nil)
        let block = try #require(parsed.contextBlock)
        #expect(!block.contains("Server Notes"))
        #expect(block.contains("- backup: Back up databases. (~/.agents/skills/backup/SKILL.md)"))
    }

    @Test("超长 AGENTS.md 与技能描述会被裁剪")
    func truncation() throws {
        let longNotes = String(repeating: "a", count: ServerAgentInstructions.maxAgentsMarkdownChars + 500)
        let longDescription = String(repeating: "d", count: 400)
        let output = longNotes + "\n<<<CONCHTALK_SKILLS>>>\n<<<SKILL /srv/x/.agents/skills/big/SKILL.md>>>\n---\nname: big\ndescription: \(longDescription)\n---\n"
        let parsed = try #require(ServerAgentInstructions.parse(output))
        let notes = try #require(parsed.agentsMarkdown)
        #expect(notes.hasPrefix(String(repeating: "a", count: ServerAgentInstructions.maxAgentsMarkdownChars)))
        #expect(notes.hasSuffix("[AGENTS.md truncated; read the file for the rest]"))
        #expect(parsed.skills.first?.description.count == ServerAgentInstructions.maxSkillDescriptionChars)
    }

    @Test("技能数量受上限约束")
    func skillLimit() throws {
        var output = "\n<<<CONCHTALK_SKILLS>>>\n"
        for index in 0..<(ServerAgentInstructions.maxSkills + 5) {
            output += "<<<SKILL /h/.agents/skills/s\(index)/SKILL.md>>>\n---\nname: s\(index)\ndescription: skill \(index)\n---\n"
        }
        let parsed = try #require(ServerAgentInstructions.parse(output))
        #expect(parsed.skills.count == ServerAgentInstructions.maxSkills)
    }

    @Test("路径显示：优先替换已知 home，否则按 .agents/skills 推断")
    func displayPath() {
        #expect(ServerAgentInstructions.displayPath("/home/a/notes/x", home: "/home/a") == "~/notes/x")
        #expect(ServerAgentInstructions.displayPath("/opt/u/.agents/skills/k/SKILL.md", home: nil) == "~/.agents/skills/k/SKILL.md")
        #expect(ServerAgentInstructions.displayPath("/weird/path", home: nil) == "/weird/path")
    }

    @Test("探测命令只读：用 sh 包裹，只读取固定位置，不含写入重定向")
    func probeCommandIsReadOnly() {
        let command = ServerAgentInstructions.probeCommand
        #expect(command.hasPrefix("sh -c '"))
        #expect(command.contains("$HOME/AGENTS.md"))
        #expect(command.contains("\"$HOME\"/.agents/skills/*/SKILL.md"))
        // 除了 stderr 丢弃（2>/dev/null）与 printf 中的标记文字外，不应出现任何输出重定向。
        let stripped = command
            .replacingOccurrences(of: "2>/dev/null", with: "")
            .replacingOccurrences(of: ServerAgentInstructions.skillsMarker, with: "")
            .replacingOccurrences(of: ServerAgentInstructions.skillSuffix, with: "")
        #expect(!stripped.contains(">"))
        for forbidden in ["rm ", "mv ", "cp ", "tee ", "sed -i", "chmod", "curl", "wget"] {
            #expect(!command.contains(forbidden), "命令不应包含 \(forbidden)")
        }
    }
}
