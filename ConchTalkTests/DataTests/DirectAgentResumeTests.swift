/// 文件说明：DirectAgentResumeTests，验证直连代理会话恢复：存储、各协议恢复请求与协调器恢复 / 清空流程。
import Testing
@testable import ConchTalk
import Foundation
@preconcurrency import ACPModel

// MARK: - 存储与校验

@Suite("DirectAgentResumeStore")
struct DirectAgentResumeStoreTests {

    private func makeStore() -> (DirectAgentResumeStore, UserDefaults) {
        let suite = "DirectAgentResumeStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (DirectAgentResumeStore(defaults: defaults), defaults)
    }

    @Test("按服务器 / 代理 / 目录隔离保存与读取")
    func savesPerScope() {
        let (store, _) = makeStore()
        let server = UUID()
        store.save("sess-1", serverID: server, agentType: .claude, cwd: "/srv/app")
        #expect(store.sessionId(serverID: server, agentType: .claude, cwd: "/srv/app") == "sess-1")
        #expect(store.sessionId(serverID: server, agentType: .claude, cwd: "/srv/other") == nil)
        #expect(store.sessionId(serverID: server, agentType: .codex, cwd: "/srv/app") == nil)
        #expect(store.sessionId(serverID: UUID(), agentType: .claude, cwd: "/srv/app") == nil)
    }

    @Test("过期记录被丢弃，clear 后不再恢复")
    func expiresAndClears() {
        let (store, _) = makeStore()
        let server = UUID()
        let old = Date(timeIntervalSinceNow: -DirectAgentResumeStore.maxAge - 60)
        store.save("sess-old", serverID: server, agentType: .codex, cwd: nil, now: old)
        #expect(store.sessionId(serverID: server, agentType: .codex, cwd: nil) == nil)

        store.save("sess-2", serverID: server, agentType: .codex, cwd: nil)
        store.clear(serverID: server, agentType: .codex, cwd: nil)
        #expect(store.sessionId(serverID: server, agentType: .codex, cwd: nil) == nil)
    }

    @Test("不安全的会话 ID 不保存也不返回")
    func rejectsUnsafeIDs() {
        let (store, _) = makeStore()
        let server = UUID()
        store.save("abc; rm -rf ~", serverID: server, agentType: .claude, cwd: nil)
        #expect(store.sessionId(serverID: server, agentType: .claude, cwd: nil) == nil)
        #expect(AgentSessionIdValidator.isSafe("1f0c6a2e-8d6b-4a51-9d1e-3b0f7d2c9a11"))
        #expect(AgentSessionIdValidator.isSafe("thr_123"))
        #expect(!AgentSessionIdValidator.isSafe("a'b"))
        #expect(!AgentSessionIdValidator.isSafe(""))
        #expect(!AgentSessionIdValidator.isSafe("$(whoami)"))
    }
}

// MARK: - 协议层

@Suite("Direct agent resume protocol")
struct DirectAgentResumeProtocolTests {

    @Test("Claude Code：安全 ID 追加 --resume，不安全 ID 忽略")
    func claudeResumeFlag() {
        let resumed = ClaudeCodeCommandBuilder.launchCommand(cwd: "/srv/app", resumeSessionId: "1f0c6a2e-8d6b")
        #expect(resumed.contains("exec claude -p --resume 1f0c6a2e-8d6b --output-format stream-json"))
        let fresh = ClaudeCodeCommandBuilder.launchCommand(cwd: "/srv/app")
        #expect(!fresh.contains("--resume"))
        let unsafe = ClaudeCodeCommandBuilder.launchCommand(cwd: "/srv/app", resumeSessionId: "x;reboot")
        #expect(!unsafe.contains("--resume"))
        #expect(!unsafe.contains("reboot"))
    }

    @Test("Codex：thread/resume 携带 threadId / cwd / approvalPolicy，响应解析 thread.id")
    func codexThreadResume() throws {
        let request = CodexRPCRequest.threadResume(id: 7, threadId: "thr_123", cwd: "/srv/app")
        let json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        #expect(json["method"] as? String == "thread/resume")
        let params = try #require(json["params"] as? [String: Any])
        #expect(params["threadId"] as? String == "thr_123")
        #expect(params["cwd"] as? String == "/srv/app")
        #expect(params["approvalPolicy"] as? String == "on-request")

        let ok = try JSONDecoder().decode(CodexRPCResponse.self, from: Data(#"{"id":7,"result":{"thread":{"id":"thr_123"}}}"#.utf8))
        #expect(CodexConnection.threadId(from: ok) == "thr_123")
        let failed = try JSONDecoder().decode(CodexRPCResponse.self, from: Data(#"{"id":7,"error":{"code":-32600,"message":"thread not found"}}"#.utf8))
        #expect(CodexConnection.threadId(from: failed) == nil)
    }

    @Test("ACP：resume 优先于 load，均不支持返回 nil")
    func acpRestorePreference() {
        let both = AgentCapabilities(loadSession: true, sessionCapabilities: SessionCapabilities(resume: SessionResumeCapabilities()))
        #expect(ACPSessionRestoreMethod.preferred(for: both) == .resume)
        #expect(ACPSessionRestoreMethod.preferred(for: AgentCapabilities(loadSession: true)) == .load)
        #expect(ACPSessionRestoreMethod.preferred(for: AgentCapabilities()) == nil)
        #expect(ACPSessionRestoreMethod.preferred(for: nil) == nil)
    }

    @Test("ACP：session/load 回放只丢弃内容类 update，保留命令 / 配置 / 用量")
    func replayFilter() {
        #expect(ACPClientConnection.isReplayedContent(.agentMessageChunk(.text(TextContent(text: "old")))))
        #expect(ACPClientConnection.isReplayedContent(.userMessageChunk(.text(TextContent(text: "old")))))
        #expect(!ACPClientConnection.isReplayedContent(.availableCommandsUpdate([])))
        #expect(!ACPClientConnection.isReplayedContent(.usageUpdate(UsageUpdate(used: 1, size: 2))))
    }

    @Test("ACP：session/resume 请求参数符合规范")
    func restorePayload() throws {
        let data = try JSONEncoder().encode(SessionRestoreRequestPayload(sessionId: "sess_1", cwd: "/srv"))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["sessionId"] as? String == "sess_1")
        #expect(json["cwd"] as? String == "/srv")
        #expect((json["mcpServers"] as? [Any])?.isEmpty == true)
    }

    @Test("上下文用量比例与紧凑显示")
    func contextUsage() {
        #expect(DirectContextUsage(used: 50_000, size: 200_000).fraction == 0.25)
        #expect(DirectContextUsage(used: 1, size: 0).fraction == nil)
        #expect(DirectContextUsage.compact(90_500) == "90K")
        #expect(DirectContextUsage.compact(512) == "512")
    }
}

// MARK: - 协调器

/// 支持恢复的会话替身：记录收到的 resumeSessionId，并按 `acceptResume` 决定是否恢复成功。
actor ResumableFakeSession: DirectAgentSessionType {
    let agentInfo: ConchTalk.AgentInfo
    let acceptResume: Bool
    let newSessionId: String
    private(set) var receivedResumeId: String?
    private(set) var resumed = false

    init(agentInfo: ConchTalk.AgentInfo, acceptResume: Bool, newSessionId: String) {
        self.agentInfo = agentInfo
        self.acceptResume = acceptResume
        self.newSessionId = newSessionId
    }

    var configOptions: [SessionConfigOption] { [] }
    var availableCommands: [AvailableCommand] { [] }
    var modelsInfo: ModelsInfo? { nil }
    var modesInfo: ModesInfo? { nil }

    func setUpdateHandler(_ handler: @escaping @Sendable (SessionUpdate) -> Void) async {}
    func setDisconnectHandler(_ handler: @escaping @Sendable () -> Void) async {}
    func setConfigUpdateHandler(_ handler: @escaping @Sendable () -> Void) async {}
    func setPermissionHandler(_ handler: @escaping @Sendable (ACPPermissionRequest) async -> Bool) async {}

    func connect(cwd: String?) async throws -> String {
        try await connect(cwd: cwd, resumeSessionId: nil)
    }

    func connect(cwd: String?, resumeSessionId: String?) async throws -> String {
        receivedResumeId = resumeSessionId
        resumed = resumeSessionId != nil && acceptResume
        return "Fake Agent"
    }

    var agentSessionId: String? { resumed ? receivedResumeId : newSessionId }
    var didResumeSession: Bool { resumed }

    func sendPrompt(_ text: String) async throws {}
    func cancelCurrentPrompt() async {}
    func setConfigOption(configId: SessionConfigId, value: SessionConfigValueId) async throws {}
    func setConfigOption(configId: SessionConfigId, value: Bool) async throws {}
    func setModel(modelId: String) async throws {}
    func setMode(modeId: String) async throws {}
    func disconnect() async {}
}

@Suite("DirectSessionCoordinator resume")
@MainActor
struct DirectSessionCoordinatorResumeTests {

    private func makeStore() -> DirectAgentResumeStore {
        let suite = "DirectSessionCoordinatorResumeTests.\(UUID().uuidString)"
        return DirectAgentResumeStore(defaults: UserDefaults(suiteName: suite)!)
    }

    /// 依次产出给定会话的工厂。
    private func factory(_ sessions: [ResumableFakeSession]) -> DirectSessionCoordinator.SessionFactory {
        let queue = LockedBox(sessions)
        return { _, _ in
            queue.withValue { $0.removeFirst() }
        }
    }

    private func waitForResumedEvent(_ box: LockedBox<[String]>) async -> [String] {
        for _ in 0..<50 where box.value.isEmpty {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return box.value
    }

    @Test("首次连接记录会话 ID；再次连接同一作用域时恢复并发出事件；清空上下文后新建")
    func resumesAndRotates() async throws {
        let store = makeStore()
        let server = UUID()
        let agent = AgentInfo(type: .claude, path: "/usr/bin/claude", version: nil)

        // 1. 首次连接：无记录，新建并保存
        let first = ResumableFakeSession(agentInfo: agent, acceptResume: true, newSessionId: "sess-1")
        let coordinator1 = DirectSessionCoordinator(resumeStore: store, sessionFactory: factory([first]))
        await coordinator1.connect(agent: agent, cwd: "/srv/app", resumeServerID: server)
        #expect(await first.receivedResumeId == nil)
        #expect(store.sessionId(serverID: server, agentType: .claude, cwd: "/srv/app") == "sess-1")

        // 2. 再次连接：带记录的 ID 恢复，并发出 sessionResumed
        let second = ResumableFakeSession(agentInfo: agent, acceptResume: true, newSessionId: "sess-unused")
        let rotated = ResumableFakeSession(agentInfo: agent, acceptResume: true, newSessionId: "sess-3")
        let coordinator2 = DirectSessionCoordinator(resumeStore: store, sessionFactory: factory([second, rotated]))
        let resumedNames = LockedBox<[String]>([])
        let collect = Task { @MainActor in
            for await event in coordinator2.events {
                if case .sessionResumed(let name) = event { resumedNames.withValue { $0.append(name) } }
            }
        }
        await coordinator2.connect(agent: agent, cwd: "/srv/app", resumeServerID: server)
        #expect(await second.receivedResumeId == "sess-1")
        #expect(await waitForResumedEvent(resumedNames) == ["Fake Agent"])

        // 3. 清空上下文：清除记录并新建会话（不传 resume ID），保存新 ID
        #expect(await coordinator2.rotateAfterContextBreak())
        #expect(await rotated.receivedResumeId == nil)
        #expect(store.sessionId(serverID: server, agentType: .claude, cwd: "/srv/app") == "sess-3")
        collect.cancel()
    }

    @Test("恢复失败（代理新建会话）时不发出恢复事件，并保存新会话 ID")
    func resumeFallbackSavesNewID() async throws {
        let store = makeStore()
        let server = UUID()
        let agent = AgentInfo(type: .codex, path: "/usr/bin/codex", version: nil)
        store.save("thr_gone", serverID: server, agentType: .codex, cwd: nil)

        let session = ResumableFakeSession(agentInfo: agent, acceptResume: false, newSessionId: "thr_new")
        let coordinator = DirectSessionCoordinator(resumeStore: store, sessionFactory: factory([session]))
        let resumedNames = LockedBox<[String]>([])
        let collect = Task { @MainActor in
            for await event in coordinator.events {
                if case .sessionResumed(let name) = event { resumedNames.withValue { $0.append(name) } }
            }
        }
        await coordinator.connect(agent: agent, resumeServerID: server)
        #expect(await session.receivedResumeId == "thr_gone")
        try? await Task.sleep(for: .milliseconds(100))
        #expect(resumedNames.value.isEmpty)
        #expect(store.sessionId(serverID: server, agentType: .codex, cwd: nil) == "thr_new")
        collect.cancel()
    }

    @Test("未提供 resumeServerID 时不读写恢复记录")
    func noScopeNoResume() async {
        let store = makeStore()
        let agent = AgentInfo(type: .claude, path: "/usr/bin/claude", version: nil)
        let session = ResumableFakeSession(agentInfo: agent, acceptResume: true, newSessionId: "sess-x")
        let coordinator = DirectSessionCoordinator(resumeStore: store, sessionFactory: factory([session]))
        await coordinator.connect(agent: agent, cwd: "/srv")
        #expect(await session.receivedResumeId == nil)
    }
}
