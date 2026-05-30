/// 文件说明：DirectSessionTestDoubles，直连模式测试共享的 Fake/Stub/辅助类型。
import Foundation
@testable import ConchTalk
@preconcurrency import ACPModel

// MARK: - Session 探针

actor SessionProbePool {
    private(set) var probes: [SessionProbe] = []
    private(set) var sessions: [FakeDirectAgentSession] = []

    func append(_ probe: SessionProbe) {
        probes.append(probe)
    }

    func appendSession(_ session: FakeDirectAgentSession) {
        sessions.append(session)
    }

    func firstDisconnectCount() async -> Int? {
        guard let first = probes.first else { return nil }
        return await first.disconnectCount
    }

    func firstSession() -> FakeDirectAgentSession? {
        sessions.first
    }
}

actor SessionProbe {
    private(set) var disconnectCount = 0
    private(set) var cancelPromptCount = 0

    func recordDisconnect() {
        disconnectCount += 1
    }

    func recordCancelPrompt() {
        cancelPromptCount += 1
    }
}

// MARK: - Fake DirectAgentSession

actor FakeDirectAgentSession: DirectAgentSessionType {
    let agentInfo: ConchTalk.AgentInfo
    let displayName: String
    let connectError: Error?
    var configOptions: [SessionConfigOption]
    var availableCommands: [AvailableCommand]
    var modelsInfo: ModelsInfo?
    var modesInfo: ModesInfo?

    private let promptBehavior: PromptBehavior
    private let connectBehavior: ConnectBehavior
    private let probe: SessionProbe
    private var disconnectHandler: (@Sendable () -> Void)?
    private var updateHandler: (@Sendable (SessionUpdate) -> Void)?
    private var promptContinuation: CheckedContinuation<Void, Error>?

    init(
        agentInfo: ConchTalk.AgentInfo,
        displayName: String,
        connectError: Error?,
        configOptions: [SessionConfigOption] = [],
        availableCommands: [AvailableCommand] = [],
        modelsInfo: ModelsInfo? = nil,
        modesInfo: ModesInfo? = nil,
        promptBehavior: PromptBehavior = .succeedImmediate,
        connectBehavior: ConnectBehavior = .succeedImmediate,
        probe: SessionProbe
    ) {
        self.agentInfo = agentInfo
        self.displayName = displayName
        self.connectError = connectError
        self.configOptions = configOptions
        self.availableCommands = availableCommands
        self.modelsInfo = modelsInfo
        self.modesInfo = modesInfo
        self.promptBehavior = promptBehavior
        self.connectBehavior = connectBehavior
        self.probe = probe
    }

    func setUpdateHandler(_ handler: @escaping @Sendable (SessionUpdate) -> Void) async {
        updateHandler = handler
    }

    func setDisconnectHandler(_ handler: @escaping @Sendable () -> Void) async {
        disconnectHandler = handler
    }

    func setConfigUpdateHandler(_ handler: @escaping @Sendable () -> Void) async {}

    func connect(cwd: String?) async throws -> String {
        if let connectError { throw connectError }

        switch connectBehavior {
        case .succeedImmediate:
            return displayName
        case .waitForCancellation:
            return try await withTaskCancellationHandler {
                try await Task.sleep(for: .seconds(60))
                return displayName
            } onCancel: {}
        }
    }

    func sendPrompt(_ text: String) async throws {
        switch promptBehavior {
        case .succeedImmediate:
            updateHandler?(.agentThoughtChunk(.text(TextContent(text: "thinking"))))
            updateHandler?(.agentMessageChunk(.text(TextContent(text: "reply"))))
            return
        case .waitForDisconnect:
            try await withCheckedThrowingContinuation { continuation in
                promptContinuation = continuation
            }
        case .streamThenDisconnect:
            updateHandler?(.agentThoughtChunk(.text(TextContent(text: "thinking"))))
            updateHandler?(.agentMessageChunk(.text(TextContent(text: "partial reply"))))
            throw ACPConnectionError.disconnected
        }
    }

    func cancelCurrentPrompt() async {
        await probe.recordCancelPrompt()
        promptContinuation?.resume(throwing: CancellationError())
        promptContinuation = nil
    }

    func setConfigOption(configId: SessionConfigId, value: SessionConfigValueId) async throws {}
    func setConfigOption(configId: SessionConfigId, value: Bool) async throws {}
    func setModel(modelId: String) async throws {}
    func setMode(modeId: String) async throws {}

    func emit(_ update: SessionUpdate) {
        updateHandler?(update)
    }

    func disconnect() async {
        await probe.recordDisconnect()
        promptContinuation?.resume(throwing: ACPConnectionError.disconnected)
        promptContinuation = nil
        disconnectHandler?()
    }
}

// MARK: - Session 工厂辅助类型

enum SessionFactoryOutcome {
    case success(
        displayName: String,
        configOptions: [SessionConfigOption] = [],
        availableCommands: [AvailableCommand] = [],
        modelsInfo: ModelsInfo? = nil,
        modesInfo: ModesInfo? = nil,
        promptBehavior: PromptBehavior = .succeedImmediate,
        connectBehavior: ConnectBehavior = .succeedImmediate
    )
    case failure(message: String)
}

enum PromptBehavior {
    case succeedImmediate
    case waitForDisconnect
    case streamThenDisconnect
}

enum ConnectBehavior {
    case succeedImmediate
    case waitForCancellation
}

struct TestSessionError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// 为 DirectSessionCoordinator 创建测试用的 SessionFactory。
func makeCoordinatorSessionFactory(
    _ outcomes: [SessionFactoryOutcome],
    probes: SessionProbePool
) -> DirectSessionCoordinator.SessionFactory {
    let remaining = LockedBox(outcomes)

    return { agent, _ in
        let next = remaining.withValue { queue in
            queue.isEmpty ? .success(displayName: agent.type.displayName) : queue.removeFirst()
        }

        let probe = SessionProbe()
        Task {
            await probes.append(probe)
        }

        switch next {
        case .success(let displayName, let configOptions, let availableCommands, let modelsInfo, let modesInfo, let promptBehavior, let connectBehavior):
            let session = FakeDirectAgentSession(
                agentInfo: agent,
                displayName: displayName,
                connectError: Optional<Error>.none,
                configOptions: configOptions,
                availableCommands: availableCommands,
                modelsInfo: modelsInfo,
                modesInfo: modesInfo,
                promptBehavior: promptBehavior,
                connectBehavior: connectBehavior,
                probe: probe
            )
            Task {
                await probes.appendSession(session)
            }
            return session
        case .failure(let message):
            let session = FakeDirectAgentSession(
                agentInfo: agent,
                displayName: agent.type.displayName,
                connectError: TestSessionError(message: message),
                probe: probe
            )
            Task {
                await probes.appendSession(session)
            }
            return session
        }
    }
}
