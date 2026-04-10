/// 文件说明：ClaudeCodeConnection，Claude Code CLI 的原生传输连接。

import Foundation
@preconcurrency import ACPModel
@preconcurrency import Citadel

// MARK: - 消息翻译器

/// ClaudeCodeMessageTranslator：将 Claude Code 原生消息翻译为 ACPModel SessionUpdate。
/// 纯函数集合，不持有状态，便于单元测试。
nonisolated enum ClaudeCodeMessageTranslator {

    /// 将 assistant 消息的单个 content block 翻译为 SessionUpdate。
    static func translateContentBlock(_ block: ClaudeContentBlock) -> SessionUpdate {
        switch block {
        case .text(let text):
            return .agentMessageChunk(.text(TextContent(text: text)))
        case .thinking(let text):
            return .agentThoughtChunk(.text(TextContent(text: text)))
        case .toolUse(let id, let name, let input):
            let inputStr = input.map { "\($0.key): \($0.value.stringValue ?? String(describing: $0.value))" }
                .joined(separator: ", ")
            let kind = toolKind(for: name)
            return .toolCall(ToolCallUpdate(
                toolCallId: id,
                status: .inProgress,
                title: "\(name): \(String(inputStr.prefix(100)))",
                kind: kind
            ))
        }
    }

    /// 将 user 消息中的 tool_result 翻译为 SessionUpdate。
    static func translateToolResult(_ result: ClaudeToolResultContent) -> SessionUpdate {
        .toolCallUpdate(ToolCallUpdateDetails(
            toolCallId: result.toolUseId ?? "unknown",
            status: .completed,
            content: result.content.map { [.content(.text(TextContent(text: $0)))] }
        ))
    }

    /// 从 control_request 构造权限请求描述文本。
    static func permissionDescription(from request: ClaudeControlRequest) -> String {
        if let title = request.request.title {
            return title
        }
        let toolName = request.request.toolName ?? "unknown"
        let inputStr = request.request.input?
            .map { "\($0.key): \($0.value.stringValue ?? String(describing: $0.value))" }
            .joined(separator: ", ") ?? ""
        return "\(toolName)(\(inputStr))"
    }

    /// 根据 Claude Code 工具名推断 ACP ToolKind。
    private static func toolKind(for toolName: String) -> ToolKind {
        switch toolName {
        case "Bash": return .execute
        case "Read", "Glob", "Grep": return .read
        case "Edit", "Write": return .edit
        case "WebFetch", "WebSearch": return .fetch
        default: return .execute
        }
    }
}

// MARK: - ClaudeCodeConnection

/// ClaudeCodeConnection：通过 SSH 直接与 Claude Code CLI 通信。
///
/// 架构：持久进程模式。启动一个 `claude -p --input-format stream-json --output-format stream-json` 进程，
/// 通过 stdin 持续发送 JSON prompt，stdout 接收 NDJSON 流式输出。
/// 关键：启动后必须立即发送第一条 JSON 消息到 stdin，否则 Claude Code 会因为 stdin 无数据而退出。
actor ClaudeCodeConnection: AgentConnection {
    private let sshClient: SSHClient
    private var transport: SSHProcessTransport?
    private var routerTask: Task<Void, Never>?
    private var sessionId: String = ""
    private let promptCompletionSignal = BufferedCompletionSignal()
    private let canceledTurnDrainSignal = BufferedCompletionSignal()
    private var isDrainingCanceledTurn = false
    private var canceledTurnDrainTask: Task<Void, Never>?

    private var updateHandler: (@Sendable (SessionUpdate) -> Void)?
    private var disconnectHandler: (@Sendable () -> Void)?

    /// 权限请求回调：由 DirectAgentSession 设置，桥接到 UI 审批流程。
    var permissionRequestHandler: (@Sendable (ACPPermissionRequest) async -> Bool)?

    /// 可用的 slash commands（从 system.init 提取）。
    private(set) var availableCommands: [AvailableCommand] = []
    private(set) var modelsInfo: ModelsInfo?
    private(set) var modesInfo: ModesInfo?
    private(set) var configOptions: [SessionConfigOption] = []

    init(sshClient: SSHClient) {
        self.sshClient = sshClient
    }

    func setUpdateHandler(_ handler: @escaping @Sendable (SessionUpdate) -> Void) {
        updateHandler = handler
    }

    func setDisconnectHandler(_ handler: @escaping @Sendable () -> Void) {
        disconnectHandler = handler
    }

    func setConfigUpdateHandler(_ handler: @escaping @Sendable () -> Void) {}

    // MARK: - AgentConnection

    func connect(cwd: String) async throws -> AgentConnectionInfo {
        print("[ClaudeCodeConnection] connect() called, cwd=\(cwd)")

        // 启动持久 Claude Code 进程
        let escapedCwd = cwd.replacingOccurrences(of: "'", with: "'\\''")
        let command = "sh -c 'cd \"\(escapedCwd)\" && exec claude -p --output-format stream-json --input-format stream-json --verbose'"
        let proc = SSHProcessTransport(sshClient: sshClient, command: command)
        try await proc.start()
        self.transport = proc

        // 正常模式：完整 init 握手

        // 关键：立即发送初始化 prompt 到 stdin，否则 Claude Code 会因 stdin 无数据退出。
        // /cost 不消耗 token，仅触发 init 流程。
        let initPrompt = ClaudeCodeUserMessage(text: "/cost")
        let initData = try JSONEncoder().encode(initPrompt)
        guard let initJson = String(data: initData, encoding: .utf8) else {
            throw ACPTransportError.encodingFailed
        }
        try await proc.writeLine(initJson)
        print("[ClaudeCodeConnection] Sent initial /cost prompt to stdin")

        // 等待 system.init 消息
        var iterator = proc.lines.makeAsyncIterator()
        let initMessage = try await waitForSystemInit(iterator: &iterator)
        self.sessionId = initMessage.sessionId

        // 等待初始 /cost 的 result 消息
        try await waitForResult(iterator: &iterator)
        print("[ClaudeCodeConnection] Init complete, session=\(sessionId)")

        // 启动持久消息路由
        startMessageRouter(iterator: iterator)

        // 构建 models 和 commands
        let modelsInfo = Self.buildModelsInfo(from: initMessage)
        let commands = Self.buildAvailableCommands(from: initMessage)
        self.modelsInfo = modelsInfo
        self.availableCommands = commands

        let version = initMessage.claudeCodeVersion ?? ""
        let displayName = version.isEmpty ? "Claude Code" : "Claude Code \(version)"

        return AgentConnectionInfo(
            displayName: displayName,
            models: modelsInfo,
            modes: nil,
            configOptions: [],
            availableCommands: commands
        )
    }

    func sendPrompt(_ text: String) async throws {
        guard let transport else {
            throw ACPConnectionError.notConnected
        }
        if isDrainingCanceledTurn {
            try await canceledTurnDrainSignal.wait()
        }
        let turnToken = await promptCompletionSignal.beginTurn()

        // 通过 stdin 发送 JSON prompt 到持久进程
        let msg = ClaudeCodeUserMessage(text: text, sessionId: sessionId)
        let data = try JSONEncoder().encode(msg)
        guard let json = String(data: data, encoding: .utf8) else {
            throw ACPTransportError.encodingFailed
        }
        try await transport.writeLine(json)

        // 等待 result 消息（允许 result 早于 wait 注册到达）。
        try await promptCompletionSignal.wait(for: turnToken)
    }

    func cancelPrompt() async {
        let turnToken = await promptCompletionSignal.activeTurnToken()
        guard turnToken > 0 else { return }
        isDrainingCanceledTurn = true
        await promptCompletionSignal.fail(CancellationError(), for: turnToken)
        canceledTurnDrainTask?.cancel()
        canceledTurnDrainTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            await self?.finishCanceledTurnDrainIfNeeded()
        }
        try? await transport?.writeRaw("\u{03}")
    }

    func disconnect() async {
        routerTask?.cancel()
        routerTask = nil
        await transport?.close()
        transport = nil
        let turnToken = await promptCompletionSignal.activeTurnToken()
        if turnToken > 0 {
            await promptCompletionSignal.fail(ACPConnectionError.disconnected, for: turnToken)
        }
    }

    // MARK: - Init 阶段（顺序消费迭代器）

    /// 等待 system.init 消息（跳过 hook_started / hook_response 等非 init system 消息）。
    private func waitForSystemInit(
        iterator: inout AsyncThrowingStream<String, Error>.AsyncIterator
    ) async throws -> ClaudeSystemInit {
        let decoder = JSONDecoder()
        while let line = try await iterator.next() {
            guard line.hasPrefix("{"), let data = line.data(using: .utf8) else { continue }
            do {
                let msg = try decoder.decode(ClaudeCodeMessage.self, from: data)
                if case .system(let initMsg) = msg, initMsg.isInit {
                    print("[ClaudeCodeConnection] system.init received, session=\(initMsg.sessionId)")
                    return initMsg
                }
            } catch {
                print("[ClaudeCodeConnection] waitForInit decode error: \(error)")
            }
        }
        throw ACPConnectionError.protocolError("Claude Code exited without sending system.init")
    }

    /// 等待 result 消息（初始化阶段用，消费同一个迭代器）。
    private func waitForResult(
        iterator: inout AsyncThrowingStream<String, Error>.AsyncIterator
    ) async throws {
        let decoder = JSONDecoder()
        while let line = try await iterator.next() {
            guard line.hasPrefix("{"), let data = line.data(using: .utf8) else { continue }
            if let msg = try? decoder.decode(ClaudeCodeMessage.self, from: data),
               case .result = msg {
                return
            }
        }
        throw ACPConnectionError.protocolError("Claude Code exited without sending result")
    }

    // MARK: - 持久消息路由

    /// 启动持久消息路由（从迭代器持续消费消息，直到进程退出）。
    private func startMessageRouter(iterator: AsyncThrowingStream<String, Error>.AsyncIterator) {
        var iter = iterator
        let decoder = JSONDecoder()

        routerTask = Task { [weak self] in
            do {
                while let line = try await iter.next() {
                    guard let self else { return }
                    guard line.hasPrefix("{"), let data = line.data(using: .utf8) else { continue }
                    guard let msg = try? decoder.decode(ClaudeCodeMessage.self, from: data) else { continue }
                    await self.handleMessage(msg)
                }
                await self?.handleUnexpectedExit()
            } catch {
                await self?.handleUnexpectedExit()
            }
        }
    }

    /// 处理单条消息。
    private func handleMessage(_ msg: ClaudeCodeMessage) async {
        switch msg {
        case .system:
            break  // init 已在 connect() 中处理

        case .assistant(let assistantMsg):
            for block in assistantMsg.message.content {
                let update = ClaudeCodeMessageTranslator.translateContentBlock(block)
                updateHandler?(update)
            }

        case .user(let userMsg):
            if let content = userMsg.message?.content {
                for item in content where item.type == "tool_result" {
                    let update = ClaudeCodeMessageTranslator.translateToolResult(item)
                    updateHandler?(update)
                }
            }

        case .result:
            await resolveResult()

        case .controlRequest(let req):
            await handlePermissionRequest(req)

        case .keepAlive:
            break
        }
    }

    private func resolveResult() async {
        if isDrainingCanceledTurn {
            isDrainingCanceledTurn = false
            canceledTurnDrainTask?.cancel()
            canceledTurnDrainTask = nil
            await canceledTurnDrainSignal.succeed()
            return
        }
        let turnToken = await promptCompletionSignal.activeTurnToken()
        guard turnToken > 0 else { return }
        await promptCompletionSignal.succeed(for: turnToken)
    }

    // MARK: - 权限处理

    private func handlePermissionRequest(_ req: ClaudeControlRequest) async {
        let description = ClaudeCodeMessageTranslator.permissionDescription(from: req)

        let update = SessionUpdate.toolCall(ToolCallUpdate(
            toolCallId: req.requestId,
            status: .pending,
            title: description,
            kind: .execute
        ))
        updateHandler?(update)

        let permRequest = ACPPermissionRequest(
            description: description,
            tool: req.request.toolName,
            arguments: nil
        )
        let approved = await permissionRequestHandler?(permRequest) ?? false

        let response: ClaudeCodeControlResponse
        if approved {
            response = ClaudeCodeControlResponse.allow(requestId: req.requestId)
        } else {
            response = ClaudeCodeControlResponse.deny(requestId: req.requestId, message: "User denied")
        }

        if let data = try? JSONEncoder().encode(response),
           let json = String(data: data, encoding: .utf8) {
            try? await transport?.writeLine(json)
        }
    }

    private func handleUnexpectedExit() async {
        if isDrainingCanceledTurn {
            isDrainingCanceledTurn = false
            canceledTurnDrainTask?.cancel()
            canceledTurnDrainTask = nil
            await canceledTurnDrainSignal.fail(ACPConnectionError.disconnected)
        }
        let turnToken = await promptCompletionSignal.activeTurnToken()
        if turnToken > 0 {
            await promptCompletionSignal.fail(ACPConnectionError.disconnected, for: turnToken)
        }
        disconnectHandler?()
    }

    private func finishCanceledTurnDrainIfNeeded() async {
        guard isDrainingCanceledTurn else { return }
        isDrainingCanceledTurn = false
        canceledTurnDrainTask = nil
        await canceledTurnDrainSignal.succeed()
    }

    // MARK: - Models / Commands 构建

    /// 从 system.init 构建 ModelsInfo。
    private static func buildModelsInfo(from initMsg: ClaudeSystemInit) -> ModelsInfo? {
        guard let currentModel = initMsg.model else { return nil }

        let knownModels: [(id: String, name: String)] = [
            ("claude-opus-4-6", "Claude Opus 4.6"),
            ("claude-sonnet-4-6", "Claude Sonnet 4.6"),
            ("claude-haiku-4-5", "Claude Haiku 4.5"),
        ]

        let baseModelId = currentModel.replacingOccurrences(
            of: "\\[.*\\]$", with: "", options: .regularExpression
        )

        var models = knownModels.map { ModelInfo(modelId: $0.id, name: $0.name, description: nil) }
        if !models.contains(where: { $0.modelId == baseModelId }) {
            models.insert(ModelInfo(modelId: baseModelId, name: currentModel, description: nil), at: 0)
        }

        return ModelsInfo(currentModelId: baseModelId, availableModels: models)
    }

    /// 从 system.init 的 slash_commands 构建 AvailableCommand 列表。
    private static func buildAvailableCommands(from initMsg: ClaudeSystemInit) -> [AvailableCommand] {
        guard let commands = initMsg.slashCommands else { return [] }
        return commands.map { AvailableCommand(name: $0, description: "/\($0)") }
    }
}
