/// 文件说明：AgentConnectionTests，验证 AgentConnection 协议的基本契约。

import Testing
import Foundation
@testable import ConchTalk
@preconcurrency import ACPModel

/// MockAgentConnection：用于测试的 AgentConnection mock 实现。
actor MockAgentConnection: AgentConnection {
    var isConnected = false
    var connectCalled = false
    var disconnectCalled = false
    var promptTexts: [String] = []
    var mockDisplayName = "MockAgent"
    var modelsInfo: ModelsInfo?
    var modesInfo: ModesInfo?
    var configOptions: [SessionConfigOption] = []
    var availableCommands: [AvailableCommand] = []

    private var updateHandler: (@Sendable (SessionUpdate) -> Void)?
    private(set) var disconnectHandler: (@Sendable () -> Void)?
    private var configUpdateHandler: (@Sendable () -> Void)?

    func connect(cwd: String) async throws -> AgentConnectionInfo {
        connectCalled = true
        isConnected = true
        return AgentConnectionInfo(
            displayName: mockDisplayName,
            models: modelsInfo,
            modes: modesInfo,
            configOptions: configOptions,
            availableCommands: availableCommands
        )
    }

    func sendPrompt(_ text: String) async throws {
        promptTexts.append(text)
    }

    func cancelPrompt() async {}

    func disconnect() async {
        disconnectCalled = true
        isConnected = false
    }

    func setUpdateHandler(_ handler: @escaping @Sendable (SessionUpdate) -> Void) {
        updateHandler = handler
    }

    func setDisconnectHandler(_ handler: @escaping @Sendable () -> Void) {
        disconnectHandler = handler
    }

    func setConfigUpdateHandler(_ handler: @escaping @Sendable () -> Void) {
        configUpdateHandler = handler
    }

    private(set) var permissionHandler: (@Sendable (ACPPermissionRequest) async -> Bool)?

    func setPermissionHandler(_ handler: @escaping @Sendable (ACPPermissionRequest) async -> Bool) {
        permissionHandler = handler
    }

    /// 测试用：模拟代理发起权限请求，透传给已注册 handler。
    func simulatePermissionRequest(_ request: ACPPermissionRequest) async -> Bool {
        await permissionHandler?(request) ?? false
    }

    /// 模拟异常断开，触发 disconnectHandler。
    func simulateDisconnect() {
        isConnected = false
        disconnectHandler?()
    }

    func setMetadata(
        models: ModelsInfo?,
        modes: ModesInfo?,
        configOptions: [SessionConfigOption],
        commands: [AvailableCommand]
    ) {
        self.modelsInfo = models
        self.modesInfo = modes
        self.configOptions = configOptions
        self.availableCommands = commands
    }

    func simulateMetadataUpdate(
        models: ModelsInfo?,
        modes: ModesInfo?,
        configOptions: [SessionConfigOption],
        commands: [AvailableCommand]
    ) {
        setMetadata(
            models: models,
            modes: modes,
            configOptions: configOptions,
            commands: commands
        )
        configUpdateHandler?()
    }
}

final class CallbackCounter: @unchecked Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var count = 0

    nonisolated func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    nonisolated func value() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

@Suite("AgentConnection Protocol")
struct AgentConnectionTests {
    @Test("Mock 实现满足 AgentConnection 协议契约")
    func mockConnectionLifecycle() async throws {
        let conn = MockAgentConnection()
        let info = try await conn.connect(cwd: "/tmp")
        #expect(info.displayName == "MockAgent")
        #expect(await conn.isConnected)

        try await conn.sendPrompt("hello")
        #expect(await conn.promptTexts == ["hello"])

        await conn.disconnect()
        #expect(await conn.disconnectCalled)
    }

    @Test("异常断开时 handler 被回调")
    func disconnectHandlerCalledOnUnexpectedDisconnect() async throws {
        let conn = MockAgentConnection()
        let counter = CallbackCounter()
        await conn.setDisconnectHandler {
            counter.increment()
        }
        _ = try await conn.connect(cwd: "/tmp")
        await conn.simulateDisconnect()
        #expect(counter.value() == 1)
    }

    @Test("协议边界可读取 commands/models/modes/config 元数据")
    func metadataIsReadableThroughProtocolBoundary() async throws {
        let conn = MockAgentConnection()
        await conn.setMetadata(
            models: ModelsInfo(
                currentModelId: "model.a",
                availableModels: [ModelInfo(modelId: "model.a", name: "Model A", description: nil)]
            ),
            modes: ModesInfo(
                currentModeId: "mode.default",
                availableModes: [ModeInfo(id: "mode.default", name: "Default")]
            ),
            configOptions: [],
            commands: [AvailableCommand(name: "/help", description: "Show help")]
        )

        let boundary: any AgentConnection = conn
        let info = try await boundary.connect(cwd: "/tmp")

        #expect(info.availableCommands.map(\.name) == ["/help"])
        #expect(await boundary.availableCommands.map(\.name) == ["/help"])
        #expect(await boundary.modelsInfo?.currentModelId == "model.a")
        #expect(await boundary.modesInfo?.currentModeId == "mode.default")
        #expect(await boundary.configOptions.count == 0)
    }

    @Test("协议边界可观察元数据更新")
    func metadataUpdatesSurfaceThroughProtocolBoundary() async throws {
        let conn = MockAgentConnection()
        let boundary: any AgentConnection = conn
        let counter = CallbackCounter()

        await boundary.setConfigUpdateHandler {
            counter.increment()
        }

        _ = try await boundary.connect(cwd: "/tmp")

        let updatedOptions = [
            SessionConfigOption(
                id: SessionConfigId("approval-mode"),
                name: "Approval Mode",
                description: nil,
                kind: .boolean(SessionConfigBoolean(currentValue: true))
            )
        ]

        await conn.simulateMetadataUpdate(
            models: ModelsInfo(
                currentModelId: "model.b",
                availableModels: [ModelInfo(modelId: "model.b", name: "Model B", description: nil)]
            ),
            modes: ModesInfo(
                currentModeId: "mode.review",
                availableModes: [ModeInfo(id: "mode.review", name: "Review")]
            ),
            configOptions: updatedOptions,
            commands: [AvailableCommand(name: "/run", description: "Run task")]
        )

        #expect(counter.value() == 1)
        #expect(await boundary.availableCommands.map(\.name) == ["/run"])
        #expect(await boundary.modelsInfo?.currentModelId == "model.b")
        #expect(await boundary.modesInfo?.currentModeId == "mode.review")
        #expect(await boundary.configOptions.map(\.id.value) == ["approval-mode"])
    }

    @Test("setPermissionHandler 存储 handler 且请求透传决策")
    func permissionHandlerStoredAndForwarded() async {
        let connection = MockAgentConnection()
        await connection.setPermissionHandler { request in
            request.description == "approve me"
        }

        let approved = await connection.simulatePermissionRequest(
            ACPPermissionRequest(description: "approve me", tool: nil, options: []))
        let denied = await connection.simulatePermissionRequest(
            ACPPermissionRequest(description: "other", tool: nil, options: []))
        #expect(approved)
        #expect(!denied)
    }

    @Test("ACPAgentConnection 与 DirectAgentSession 未连接时注册 handler 不崩溃")
    func setPermissionHandlerBeforeConnectIsSafe() async {
        // ACPAgentConnection：sshClient 可空，仅暂存 handler
        let acpConnection = ACPAgentConnection(
            sshClient: nil,
            agentInfo: AgentInfo(type: .gemini, path: "/usr/bin/gemini", version: nil))
        await acpConnection.setPermissionHandler { _ in true }

        // DirectAgentSession：connection 尚未创建，仅暂存
        let session = DirectAgentSession(
            agentInfo: AgentInfo(type: .gemini, path: "/usr/bin/gemini", version: nil),
            sshClient: nil)
        await session.setPermissionHandler { _ in true }
        // 走到这里未崩溃即通过；ClaudeCode/Codex 的实现由编译期协议一致性保证
        #expect(Bool(true))
    }
}
