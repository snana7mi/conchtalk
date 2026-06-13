/// 文件说明：DirectSessionCoordinatorTests，覆盖 DirectSessionCoordinator 的连接、流式、取消与 session 旋转行为。
import Testing
@testable import ConchTalk
import Foundation
@preconcurrency import ACPModel

@Suite("DirectSessionCoordinator")
@MainActor
struct DirectSessionCoordinatorTests {

    // MARK: - 辅助工厂

    /// 创建用于测试的 SessionFactory，复用 DirectModeContextBreakTests 中的 FakeDirectAgentSession。
    private func makeFactory(
        _ outcomes: [SessionFactoryOutcome],
        probes: SessionProbePool = SessionProbePool()
    ) -> (DirectSessionCoordinator.SessionFactory, SessionProbePool) {
        let pool = probes
        let factory: DirectSessionCoordinator.SessionFactory = makeCoordinatorSessionFactory(outcomes, probes: pool)
        return (factory, pool)
    }

    private func makeCoordinator(
        outcomes: [SessionFactoryOutcome],
        probes: SessionProbePool = SessionProbePool()
    ) -> (DirectSessionCoordinator, SessionProbePool) {
        let pool = probes
        let factory: DirectSessionCoordinator.SessionFactory = makeCoordinatorSessionFactory(outcomes, probes: pool)
        let coordinator = DirectSessionCoordinator(sessionFactory: factory)
        return (coordinator, pool)
    }

    // MARK: - Tests

    @Test("connect 更新生命周期并在连接成功后发布 metadata")
    func connect_updatesLifecycleAndPublishesMetadata() async throws {
        let commands = [AvailableCommand(name: "doctor", description: "Run diagnostics")]
        let models = ModelsInfo(
            currentModelId: "gpt-5",
            availableModels: [ModelInfo(modelId: "gpt-5", name: "GPT-5", description: "default")]
        )
        let modes = ModesInfo(
            currentModeId: "default",
            availableModes: [ModeInfo(id: "default", name: "Default")]
        )
        let configOptions = [
            SessionConfigOption(
                id: SessionConfigId("approval_mode"),
                name: "Approval Mode",
                kind: .boolean(SessionConfigBoolean(currentValue: true))
            )
        ]

        let (coordinator, _) = makeCoordinator(outcomes: [
            .success(
                displayName: "Codex",
                configOptions: configOptions,
                availableCommands: commands,
                modelsInfo: models,
                modesInfo: modes
            )
        ])

        let agent = AgentInfo(type: .codex, path: "/usr/bin/codex", version: nil)

        // 收集事件
        var events: [DirectSessionEvent] = []
        let collectTask = Task {
            for await event in coordinator.events {
                events.append(event)
            }
        }

        await coordinator.connect(agent: agent, cwd: "/tmp/work")

        // 验证状态
        #expect(coordinator.state.lifecycle == .connected)
        #expect(coordinator.state.activeAgent == .init(name: "Codex", type: .codex))
        #expect(coordinator.state.metadata.commands.count == 1)
        #expect(coordinator.state.metadata.commands[0].name == "doctor")
        #expect(coordinator.state.metadata.models?.currentModelId == "gpt-5")
        #expect(coordinator.state.metadata.modes?.currentModeId == "default")
        #expect(coordinator.state.metadata.configOptions.count == 1)
        #expect(coordinator.state.cwd == "/tmp/work")

        // 验证事件流中包含生命周期变化和 metadata 更新
        await Task.yield()
        let hasLifecycleConnecting = events.contains { if case .lifecycleChanged(.connecting) = $0 { return true }; return false }
        let hasLifecycleConnected = events.contains { if case .lifecycleChanged(.connected) = $0 { return true }; return false }
        let hasMetadata = events.contains { if case .metadataUpdated = $0 { return true }; return false }
        #expect(hasLifecycleConnecting)
        #expect(hasLifecycleConnected)
        #expect(hasMetadata)

        collectTask.cancel()
    }

    @Test("sendPrompt 发出流式事件但不直接操作 UI")
    func sendPrompt_emitsStreamEventsWithoutDirectUIMutation() async throws {
        let (coordinator, _) = makeCoordinator(outcomes: [
            .success(displayName: "Codex")
        ])
        let agent = AgentInfo(type: .codex, path: "/usr/bin/codex", version: nil)

        var events: [DirectSessionEvent] = []
        let collectTask = Task {
            for await event in coordinator.events {
                events.append(event)
            }
        }

        await coordinator.connect(agent: agent, cwd: "/tmp/work")
        await coordinator.sendPromptAndWait("hello")

        // 等待事件传递
        try? await Task.sleep(for: .milliseconds(100))

        // 验证生命周期回到 connected
        #expect(coordinator.state.lifecycle == .connected)

        // 验证事件流中有 streamUpdate 和 messageReady
        let hasStreamUpdate = events.contains { if case .streamUpdate = $0 { return true }; return false }
        let hasMessageReady = events.contains { if case .messageReady = $0 { return true }; return false }
        #expect(hasStreamUpdate)
        #expect(hasMessageReady)

        // 验证 messageReady 包含用户和助手消息
        let readyMessages = events.compactMap { event -> ConchTalk.Message? in
            if case .messageReady(let msg) = event { return msg }
            return nil
        }
        #expect(readyMessages.contains { $0.role == .user && $0.content == "hello" })
        #expect(readyMessages.contains { $0.role == ConchTalk.Message.MessageRole.assistant && $0.content == "reply" })

        collectTask.cancel()
    }

    @Test("cancelPrompt 重置执行状态")
    func cancelPrompt_resetsExecutionState() async throws {
        let (coordinator, _) = makeCoordinator(outcomes: [
            .success(displayName: "Codex", promptBehavior: .waitForDisconnect)
        ])
        let agent = AgentInfo(type: .codex, path: "/usr/bin/codex", version: nil)

        await coordinator.connect(agent: agent, cwd: "/tmp/work")

        // 启动一个会阻塞的 prompt
        coordinator.sendPrompt("hello")
        await Task.yield()
        #expect(coordinator.state.lifecycle == .executing)

        // 取消
        coordinator.cancelPrompt()
        try? await Task.sleep(for: .milliseconds(50))

        #expect(coordinator.state.lifecycle == .connected)
        #expect(coordinator.state.accumulatedEvents.isEmpty)
    }

    @Test("rotateAfterContextBreak 重建 session 并保留 agent 身份")
    func rotateAfterContextBreak_recreatesSessionAndPreservesAgentIdentity() async throws {
        let probes = SessionProbePool()
        let (coordinator, _) = makeCoordinator(
            outcomes: [
                .success(displayName: "Codex"),
                .success(displayName: "Codex")
            ],
            probes: probes
        )
        let agent = AgentInfo(type: .codex, path: "/usr/bin/codex", version: nil)

        await coordinator.connect(agent: agent, cwd: "/tmp/work")
        #expect(coordinator.state.lifecycle == .connected)
        #expect(coordinator.state.activeAgent?.name == "Codex")

        let rotated = await coordinator.rotateAfterContextBreak()

        #expect(rotated)
        #expect(coordinator.state.lifecycle == .connected)
        #expect(coordinator.state.activeAgent?.name == "Codex")
        #expect(coordinator.state.activeAgent?.type == .codex)
        #expect(await probes.firstDisconnectCount() == 1)
    }

    @Test("sendPrompt 在断连前已收到流式文本时直接产出回复")
    func sendPrompt_surfacesStreamedReplyBeforeDisconnectError() async throws {
        let (coordinator, _) = makeCoordinator(outcomes: [
            .success(displayName: "OpenCode", promptBehavior: .streamThenDisconnect)
        ])
        let agent = AgentInfo(type: .opencode, path: "/usr/bin/opencode", version: nil)

        var events: [DirectSessionEvent] = []
        let collectTask = Task {
            for await event in coordinator.events {
                events.append(event)
            }
        }

        await coordinator.connect(agent: agent, cwd: "/root/test")
        await coordinator.sendPromptAndWait("Hi")
        try? await Task.sleep(for: .milliseconds(100))

        let assistantMessages = events.compactMap { event -> ConchTalk.Message? in
            if case .messageReady(let msg) = event, msg.role == .assistant { return msg }
            return nil
        }

        #expect(assistantMessages.contains {
            $0.content == "partial reply" && $0.reasoningContent == "thinking"
        })
        #expect(assistantMessages.contains { $0.content.hasPrefix("Error:") } == false)

        collectTask.cancel()
    }

    @Test("disconnect 将协调器重置为 idle")
    func disconnect_resetsToIdle() async throws {
        let (coordinator, _) = makeCoordinator(outcomes: [
            .success(displayName: "Codex")
        ])
        let agent = AgentInfo(type: .codex, path: "/usr/bin/codex", version: nil)

        var events: [DirectSessionEvent] = []
        let collectTask = Task {
            for await event in coordinator.events {
                events.append(event)
            }
        }

        await coordinator.connect(agent: agent, cwd: "/tmp/work")
        _ = await coordinator.disconnect()

        #expect(coordinator.state.lifecycle == .idle)
        #expect(coordinator.state.activeAgent == nil)
        #expect(coordinator.state.metadata.commands.isEmpty)

        // 生命周期事件中应包含 disconnecting
        let hasDisconnecting = events.contains { if case .lifecycleChanged(.disconnecting) = $0 { return true }; return false }
        #expect(hasDisconnecting)

        collectTask.cancel()
    }

    @Test("connect 失败时发出 error 事件并保持 failed 状态")
    func connect_failureEmitsErrorEvent() async throws {
        let (coordinator, _) = makeCoordinator(outcomes: [
            .failure(message: "boom")
        ])
        let agent = AgentInfo(type: .codex, path: "/usr/bin/codex", version: nil)

        var events: [DirectSessionEvent] = []
        let collectTask = Task {
            for await event in coordinator.events {
                events.append(event)
            }
        }

        await coordinator.connect(agent: agent, cwd: "/tmp/work")

        #expect(coordinator.state.lifecycle == .failed(message: "boom"))

        // 单次 yield 不保证 collectTask 已消费到事件（调度敏感、并行负载下偶发失败），
        // 改为有限轮询等待 error 事件出现。
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            let hasError = events.contains { if case .error = $0 { return true }; return false }
            if hasError { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let hasError = events.contains { if case .error = $0 { return true }; return false }
        #expect(hasError)

        collectTask.cancel()
    }

    @Test("rotateAfterContextBreak 失败时回到 idle")
    func rotateAfterContextBreak_failureFallsBack() async throws {
        let probes = SessionProbePool()
        let (coordinator, _) = makeCoordinator(
            outcomes: [
                .success(displayName: "Codex"),
                .failure(message: "reconnect failed")
            ],
            probes: probes
        )
        let agent = AgentInfo(type: .codex, path: "/usr/bin/codex", version: nil)

        await coordinator.connect(agent: agent, cwd: "/tmp/work")
        let rotated = await coordinator.rotateAfterContextBreak()

        #expect(!rotated)
        #expect(coordinator.state.lifecycle == .idle)
        #expect(coordinator.state.activeAgent == nil)
    }

    @Test("session 暴露当前活跃 session")
    func session_exposesActiveDirectAgentSession() async throws {
        let (coordinator, _) = makeCoordinator(outcomes: [
            .success(displayName: "Codex")
        ])
        let agent = AgentInfo(type: .codex, path: "/usr/bin/codex", version: nil)

        // 连接前 session 为 nil
        #expect(coordinator.session == nil)

        await coordinator.connect(agent: agent, cwd: "/tmp/work")

        // 连接成功后 session 非 nil
        #expect(coordinator.session != nil)

        _ = await coordinator.disconnect()

        // 断开后 session 重置为 nil
        #expect(coordinator.session == nil)
    }

    @Test("isConnectingToAgent 反映 connecting 生命周期")
    func isConnectingToAgent_reflectsConnectingLifecycle() async throws {
        let (coordinator, _) = makeCoordinator(outcomes: [
            .success(displayName: "Codex", connectBehavior: .waitForCancellation)
        ])
        let agent = AgentInfo(type: .codex, path: "/usr/bin/codex", version: nil)

        // idle 时为 false
        #expect(!coordinator.isConnectingToAgent)

        // 启动连接（不等待完成）
        let connectTask = Task {
            await coordinator.connect(agent: agent, cwd: "/tmp/work")
        }
        await Task.yield()

        // 连接中应为 true
        #expect(coordinator.isConnectingToAgent)
        #expect(coordinator.connectingAgentType == .codex)

        connectTask.cancel()
        await connectTask.value
    }

    @Test("cancelConnecting 重置为 idle")
    func cancelConnecting_resetsToIdle() async throws {
        let (coordinator, _) = makeCoordinator(outcomes: [
            .success(displayName: "Codex", connectBehavior: .waitForCancellation)
        ])
        let agent = AgentInfo(type: .codex, path: "/usr/bin/codex", version: nil)

        // 启动连接（不等待完成）
        let connectTask = Task {
            await coordinator.connect(agent: agent, cwd: "/tmp/work")
        }
        await Task.yield()

        #expect(coordinator.state.lifecycle == .connecting)

        // 取消连接
        coordinator.cancelConnecting()
        await connectTask.value

        #expect(coordinator.state.lifecycle == .idle)
        #expect(coordinator.state.activeAgent == nil)
    }

    @Test("hasActiveSession 在 connected/executing 时为 true")
    func hasActiveSession_reflectsConnectedOrExecuting() async throws {
        let (coordinator, _) = makeCoordinator(outcomes: [
            .success(displayName: "Codex", promptBehavior: .waitForDisconnect)
        ])
        let agent = AgentInfo(type: .codex, path: "/usr/bin/codex", version: nil)

        // idle 时为 false
        #expect(!coordinator.hasActiveSession)

        await coordinator.connect(agent: agent, cwd: "/tmp/work")

        // connected 时为 true
        #expect(coordinator.hasActiveSession)

        // 启动 prompt 使其进入 executing 状态
        coordinator.sendPrompt("hello")
        await Task.yield()

        // executing 时为 true
        #expect(coordinator.hasActiveSession)

        coordinator.cancelPrompt()
        try? await Task.sleep(for: .milliseconds(50))

        // 取消后回到 connected，仍为 true
        #expect(coordinator.hasActiveSession)

        _ = await coordinator.disconnect()

        // 断开后为 false
        #expect(!coordinator.hasActiveSession)
    }

    // MARK: - 直连审批流（问题 2）

    /// SessionProbePool 的 appendSession 是异步 Task，connect 返回后可能尚未入册——轮询等待。
    private func waitForFirstSession(_ pool: SessionProbePool) async throws -> FakeDirectAgentSession {
        for _ in 0..<200 {
            if let session = await pool.firstSession() { return session }
            try await Task.sleep(for: .milliseconds(10))
        }
        return try #require(await pool.firstSession())
    }

    @Test("权限请求 yield permissionRequested 事件且 resolvePermission 回填决策")
    func permissionRequestedEventAndResolve() async throws {
        let (coordinator, pool) = makeCoordinator(outcomes: [.success(displayName: "Gemini")])
        let agent = AgentInfo(type: .gemini, path: "/usr/bin/gemini", version: nil)

        var permissionEvents: [ACPPermissionRequest] = []
        let collectTask = Task {
            for await event in coordinator.events {
                if case .permissionRequested(let request) = event {
                    permissionEvents.append(request)
                }
            }
        }

        await coordinator.connect(agent: agent, cwd: "/tmp/work")
        let session = try await waitForFirstSession(pool)

        // 模拟代理发起审批：handler 挂起直到 resolvePermission
        let request = ACPPermissionRequest(description: "Edit file", tool: "edit", options: [])
        let decisionTask = Task { await session.requestPermission(request) }

        // 等待事件抵达 UI 层
        var waited = 0
        while permissionEvents.isEmpty && waited < 200 {
            try await Task.sleep(for: .milliseconds(10))
            waited += 1
        }
        #expect(permissionEvents.first?.description == "Edit file")

        coordinator.resolvePermission(approved: true)
        let approved = await decisionTask.value
        #expect(approved)

        collectTask.cancel()
    }

    @Test("disconnect 时未决审批以 deny 解除，无泄漏")
    func disconnectResolvesPendingPermission() async throws {
        let (coordinator, pool) = makeCoordinator(outcomes: [.success(displayName: "Gemini")])
        let agent = AgentInfo(type: .gemini, path: "/usr/bin/gemini", version: nil)
        await coordinator.connect(agent: agent, cwd: "/tmp/work")
        let session = try await waitForFirstSession(pool)

        let decisionTask = Task {
            await session.requestPermission(
                ACPPermissionRequest(description: "Pending", tool: nil, options: []))
        }
        // 等待审批挂起注册到 coordinator
        try await Task.sleep(for: .milliseconds(50))

        await coordinator.disconnect()

        let approved = await decisionTask.value
        #expect(!approved)
    }
}

// makeCoordinatorSessionFactory 已移至 ConchTalkTests/Helpers/DirectSessionTestDoubles.swift
