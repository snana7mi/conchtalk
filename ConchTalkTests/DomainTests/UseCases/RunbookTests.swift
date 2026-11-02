/// 文件说明：RunbookTests，覆盖操作手册提取、Skill 渲染、存储、技能叠加与快捷指令解析。
import Testing
@testable import ConchTalk
import Foundation

@Suite("Runbook")
struct RunbookTests {
    private func messages(_ pairs: [(Message.MessageRole, String)]) -> [Message] {
        pairs.map { TestFixtures.makeMessage(role: $0.0, content: $0.1) }
    }

    @Test("成功对话提取为有序步骤，并带上上次结果")
    func extractsSuccessfulConversation() throws {
        let draft = try RunbookExtractor.extract(messages: messages([
            (.user, "检查磁盘"),
            (.assistant, "磁盘使用率 40%。"),
            (.user, "再看负载"),
            (.assistant, "负载正常。"),
        ])).get()

        #expect(draft.suggestedDisplayName == "检查磁盘")
        #expect(draft.prompt.contains("1. 检查磁盘"))
        #expect(draft.prompt.contains("2. 再看负载"))
        #expect(draft.prompt.contains("负载正常。"))
        #expect(draft.prompt.contains("in the user's language"))
    }

    @Test("上下文断点之前的请求不会进入手册")
    func ignoresMessagesBeforeContextBreak() throws {
        var cleared = TestFixtures.makeMessage(role: .system, content: "break", systemMessageType: .contextBreak)
        _ = cleared
        let draft = try RunbookExtractor.extract(messages: [
            TestFixtures.makeMessage(role: .user, content: "旧请求"),
            TestFixtures.makeMessage(role: .assistant, content: "旧结果"),
            TestFixtures.makeMessage(role: .system, content: "break", systemMessageType: .contextBreak),
            TestFixtures.makeMessage(role: .user, content: "新请求"),
            TestFixtures.makeMessage(role: .assistant, content: "新结果"),
        ]).get()
        #expect(!draft.prompt.contains("旧请求"))
        #expect(draft.prompt.contains("1. 新请求"))
        #expect(draft.suggestedDisplayName == "新请求")
    }

    @Test("没有用户请求时不能保存")
    func rejectsEmptyConversation() {
        let result = RunbookExtractor.extract(messages: messages([(.assistant, "你好")]))
        #expect(result == .failure(.noUserRequest))
    }

    @Test("停在工具调用或错误上时不能保存")
    func rejectsUnfinishedConversation() {
        let toolEnded = RunbookExtractor.extract(messages: messages([
            (.user, "重启 nginx"),
            (.command, "systemctl restart nginx"),
        ]))
        #expect(toolEnded == .failure(.notSuccessful))

        let errored = RunbookExtractor.extract(messages: [
            TestFixtures.makeMessage(role: .user, content: "重启 nginx"),
            TestFixtures.makeMessage(role: .assistant, content: "正在重启"),
            TestFixtures.makeMessage(role: .system, content: "failed", systemMessageType: .error),
        ])
        #expect(errored == .failure(.notSuccessful))
    }

    @Test("渲染结果能被 SkillParser 解析，重跑提示包含过程")
    func rendersParsableSkill() throws {
        let id = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let runbook = try RunbookSkillRenderer.make(
            displayName: "检查磁盘: \"root\"",
            messages: messages([
                (.user, "检查磁盘"),
                (.assistant, "正常"),
            ]),
            reservedNames: ["health-check"],
            sourceServerID: nil,
            id: id,
            now: Date(timeIntervalSince1970: 1_700_000_000)
        ).get()

        let skill = try #require(SkillParser.parse(runbook.skillMarkdown))
        #expect(skill.name == runbook.name)
        #expect(skill.displayName == "检查磁盘: 'root'")
        #expect(skill.metadata["kind"] == "runbook")
        #expect(runbook.name != "health-check")
        let replay = RunbookSkillRenderer.replayPrompt(for: runbook)
        #expect(replay.contains(runbook.name))
        #expect(replay.contains("检查磁盘"))
        #expect(replay.contains("in the user's language"))
    }

    @Test("中文名称落成 runbook 前缀，并避开已占用的 slug")
    func slugForNonAsciiAndCollisions() {
        let id = UUID(uuidString: "12345678-0000-0000-0000-000000000000")!
        let slug = RunbookSkillRenderer.slug(displayName: "磁盘检查", reserved: [], id: id)
        #expect(slug == "runbook-12345678")

        let taken = RunbookSkillRenderer.slug(displayName: "Disk Check", reserved: ["disk-check"], id: id)
        #expect(taken == "disk-check-2")
        #expect(SkillParser.parse("""
        ---
        name: \(taken)
        description: "collision"
        ---
        body
        """) != nil)
    }

    @Test("文件存储往返、软删除与过期清理")
    func fileStoreRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileRunbookStore(directory: directory)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let runbook = try sampleRunbook(id: UUID(), now: now)
        try store.save(runbook)
        #expect(try store.loadAll().map(\.id) == [runbook.id])

        var renamed = runbook
        renamed.displayName = "改名"
        renamed.modifiedAt = now.addingTimeInterval(10)
        try store.save(renamed)
        let loaded = try #require(try store.loadAll().first)
        #expect(loaded.displayName == "改名")
        #expect(loaded.createdAt == runbook.createdAt)

        try store.softDelete(id: runbook.id, now: now.addingTimeInterval(20))
        #expect(try store.loadAll().isEmpty)

        try store.purgeDeleted(olderThan: 30 * 24 * 60 * 60, now: now.addingTimeInterval(40))
        #expect(try store.loadAll().isEmpty)
        try store.purgeDeleted(olderThan: 5, now: now.addingTimeInterval(40))
        let raw = try Data(contentsOf: directory.appendingPathComponent("runbooks.json"))
        let records = try JSONDecoder().decode([Runbook].self, from: raw)
        #expect(records.isEmpty)
    }

    @Test("用户手册进入摘要，但不会覆盖同名内置 Skill")
    func lookupPrefersBundleSkills() throws {
        let builtin = Skill(
            name: "health-check",
            description: "Built in",
            compatibility: nil,
            metadata: [:],
            content: "builtin",
            directoryURL: nil
        )
        let lookup = MutableSkillLookup(base: SkillRegistry(preloaded: [builtin]))
        let user = try #require(SkillParser.parse(try sampleRunbook(id: UUID(), now: Date()).skillMarkdown))
        let shadow = Skill(
            name: "health-check",
            description: "Should not win",
            compatibility: nil,
            metadata: [:],
            content: "shadow",
            directoryURL: nil
        )
        lookup.replaceExtras([user, shadow])

        #expect(lookup.skill(named: "health-check")?.content == "builtin")
        #expect(lookup.skill(named: user.name)?.content == user.content)
        #expect(lookup.availableSkillNames.contains(user.name))
        #expect(lookup.skillSummaries.contains(user.name))
        #expect(!lookup.skillSummaries.contains("Should not win"))
    }

    @Test("快捷指令按手册 ID 和服务器名解析，重名时拒绝猜测")
    func resolvesIntentTargets() throws {
        let runbook = try sampleRunbook(id: UUID(), now: Date())
        let alpha = TestFixtures.makeServer(name: "Alpha")
        var beta = TestFixtures.makeServer(name: "Beta")
        beta.host = "beta.example.com"
        let otherAlpha = TestFixtures.makeServer(name: "alpha")

        let exact = try #require(try RunbookIntentResolver.resolve(
            runbookID: runbook.id.uuidString,
            serverName: "alpha",
            runbooks: [runbook],
            servers: [alpha, beta]
        ).get())
        #expect(exact.server.id == alpha.id)

        let byHost = try RunbookIntentResolver.resolve(
            runbookID: runbook.name,
            serverName: "beta.example",
            runbooks: [runbook],
            servers: [alpha, beta]
        ).get()
        #expect(byHost.server.id == beta.id)

        let ambiguous = RunbookIntentResolver.resolve(
            runbookID: runbook.id.uuidString,
            serverName: "alpha",
            runbooks: [runbook],
            servers: [alpha, otherAlpha]
        )
        #expect(ambiguous == .failure(.ambiguousServer("alpha")))

        let missing = RunbookIntentResolver.resolve(
            runbookID: "missing",
            serverName: "Alpha",
            runbooks: [runbook],
            servers: [alpha]
        )
        #expect(missing == .failure(.missingRunbook))
    }

    private func sampleRunbook(id: UUID, now: Date) throws -> Runbook {
        try RunbookSkillRenderer.make(
            displayName: "Disk",
            messages: messages([
                (.user, "Check disk"),
                (.assistant, "Disk is fine."),
            ]),
            reservedNames: [],
            sourceServerID: nil,
            id: id,
            now: now
        ).get()
    }
}
