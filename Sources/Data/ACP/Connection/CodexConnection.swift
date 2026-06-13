/// 文件说明：CodexConnection，Codex CLI app-server 的原生传输连接。

import Foundation
@preconcurrency import ACPModel
@preconcurrency import Citadel

// MARK: - 消息翻译器

/// CodexMessageTranslator：将 Codex 流式通知翻译为 ACPModel SessionUpdate。
/// 纯函数集合，不持有状态，便于单元测试。
nonisolated enum CodexMessageTranslator {

    /// 翻译 item/started 通知。
    static func translateItemStarted(_ item: CodexItem) -> SessionUpdate? {
        switch item.type {
        case "agentMessage":
            // commentary phase 的文本在 started 时可能有内容
            if item.phase == "commentary", let text = item.text, !text.isEmpty {
                return .agentThoughtChunk(.text(TextContent(text: text)))
            }
            // final_answer 的文本通过 delta 传递，started 只是标记开始
            return nil

        case "reasoning":
            // reasoning 的 content 通常在 completed 中，started 无需处理
            return nil

        case "commandExecution":
            return .toolCall(ToolCallUpdate(
                toolCallId: item.id ?? "unknown",
                status: .inProgress,
                title: item.command ?? "command",
                kind: .execute
            ))

        case "fileChange":
            return .toolCall(ToolCallUpdate(
                toolCallId: item.id ?? "unknown",
                status: .inProgress,
                title: "File change",
                kind: .edit
            ))

        case "webSearch":
            return .toolCall(ToolCallUpdate(
                toolCallId: item.id ?? "unknown",
                status: .inProgress,
                title: item.query ?? "Web search",
                kind: .fetch
            ))

        default:
            return nil
        }
    }

    /// 翻译 item/completed 通知。
    static func translateItemCompleted(_ item: CodexItem) -> SessionUpdate? {
        switch item.type {
        case "agentMessage":
            // commentary phase 的完整文本
            if item.phase == "commentary", let text = item.text, !text.isEmpty {
                return .agentThoughtChunk(.text(TextContent(text: text)))
            }
            // final_answer completed — 文本已通过 delta 发送，无需重复
            return nil

        case "commandExecution":
            let output = item.aggregatedOutput ?? item.text ?? ""
            return .toolCallUpdate(ToolCallUpdateDetails(
                toolCallId: item.id ?? "unknown",
                status: .completed,
                title: item.command,
                content: output.isEmpty ? nil : [.content(.text(TextContent(text: output)))]
            ))

        case "fileChange":
            return .toolCallUpdate(ToolCallUpdateDetails(
                toolCallId: item.id ?? "unknown",
                status: .completed,
                title: "File change",
                content: item.text.map { [.content(.text(TextContent(text: $0)))] }
            ))

        case "webSearch":
            return .toolCallUpdate(ToolCallUpdateDetails(
                toolCallId: item.id ?? "unknown",
                status: .completed,
                title: item.query
            ))

        default:
            return nil
        }
    }

    /// 翻译 agentMessage delta 文本增量。
    static func translateDelta(_ text: String) -> SessionUpdate {
        .agentMessageChunk(.text(TextContent(text: text)))
    }
}

// MARK: - CodexConnection

/// CodexConnection：通过 SSH 直接与 Codex app-server 通信。
/// 实现 JSON-RPC 握手、thread/turn 管理和流式通知解析。
actor CodexConnection: AgentConnection {
    private let sshClient: SSHClient
    private var transport: SSHProcessTransport?
    private var routerTask: Task<Void, Never>?

    private var nextRpcId = 1
    private var pendingRPC: [Int: BufferedResponseBuffer<CodexRPCResponse>] = [:]

    private var threadId: String?
    private let turnCompletionSignal = BufferedCompletionSignal()
    private let canceledTurnDrainSignal = BufferedCompletionSignal()
    private var isDrainingCanceledTurn = false
    private var canceledTurnDrainTask: Task<Void, Never>?

    private var updateHandler: (@Sendable (SessionUpdate) -> Void)?
    private var disconnectHandler: (@Sendable () -> Void)?
    private(set) var configOptions: [SessionConfigOption] = []
    private(set) var modelsInfo: ModelsInfo?
    private(set) var modesInfo: ModesInfo?

    /// 共享的行迭代器 — AsyncThrowingStream 只支持单消费者，
    /// connect() 和 messageRouter 必须使用同一个 iterator。
    private var lineIterator: AsyncThrowingStream<String, Error>.AsyncIterator?

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

    /// Codex 走自有审批协议（app-server user_input 流），本期不接入 UI 审批流；
    /// 空实现满足 AgentConnection 协议（见 spec 2.2 范围说明）。
    func setPermissionHandler(_ handler: @escaping @Sendable (ACPPermissionRequest) async -> Bool) {}

    func connect(cwd: String) async throws -> AgentConnectionInfo {
        let proc = SSHProcessTransport(sshClient: sshClient, command: "codex app-server")
        try await proc.start()
        self.transport = proc

        // 正常模式：完整握手

        // 创建共享迭代器（AsyncThrowingStream 只允许单消费者）
        var iterator = proc.lines.makeAsyncIterator()

        // initialize 握手（从共享迭代器消费响应）
        let initResp = try await sendRPCWithIterator(.initialize(id: allocRpcId()), iterator: &iterator)
        if let error = initResp.error {
            throw ACPConnectionError.protocolError("Codex initialize failed: \(error.message ?? "unknown")")
        }

        // 发现可用 models、modes、skills
        let modelsResp = try await sendRPCWithIterator(
            CodexRPCRequest(id: allocRpcId(), method: "model/list", params: .object([:])),
            iterator: &iterator
        )
        let modesResp = try await sendRPCWithIterator(
            CodexRPCRequest(id: allocRpcId(), method: "collaborationMode/list", params: .object([:])),
            iterator: &iterator
        )
        let skillsResp = try await sendRPCWithIterator(
            CodexRPCRequest(id: allocRpcId(), method: "skills/list", params: .object([:])),
            iterator: &iterator
        )

        // 解析 models
        let modelsInfo = Self.parseModelsInfo(from: modelsResp)
        // 解析 modes
        let modesInfo = Self.parseModesInfo(from: modesResp)
        // 解析 skills → AvailableCommand
        let commands = Self.parseSkillsAsCommands(from: skillsResp)
        self.modelsInfo = modelsInfo
        self.modesInfo = modesInfo

        // 创建 thread
        let threadResp = try await sendRPCWithIterator(.threadStart(id: allocRpcId(), cwd: cwd), iterator: &iterator)
        // 从 RPC 响应中提取 thread ID
        if let result = threadResp.result,
           case .object(let obj) = result,
           case .object(let thread) = obj["thread"],
           case .string(let tid) = thread["id"] {
            self.threadId = tid
        }

        // 保存 skills 为 availableCommands
        self.availableCommands = commands

        // 保存迭代器并启动消息路由
        self.lineIterator = iterator
        startMessageRouter()

        return AgentConnectionInfo(
            displayName: "Codex",
            models: modelsInfo,
            modes: modesInfo,
            configOptions: [],
            availableCommands: commands
        )
    }

    func sendPrompt(_ text: String) async throws {
        guard let tid = threadId else {
            throw ACPConnectionError.notConnected
        }
        if isDrainingCanceledTurn {
            try await canceledTurnDrainSignal.wait()
        }

        // 将 pending model/mode 随 turn/start 一起发送
        let turnToken = await turnCompletionSignal.beginTurn()
        let model = pendingModel
        pendingModel = nil
        let mode = pendingMode
        pendingMode = nil
        _ = try await sendRPC(.turnStart(
            id: allocRpcId(),
            threadId: tid,
            text: text,
            model: model,
            collaborationMode: mode
        ))

        // 等待 turn/completed 通知
        try await turnCompletionSignal.wait(for: turnToken)
    }

    func cancelPrompt() async {
        guard let tid = threadId else { return }
        let turnToken = await turnCompletionSignal.activeTurnToken()
        guard turnToken > 0 else { return }
        isDrainingCanceledTurn = true
        await turnCompletionSignal.fail(CancellationError(), for: turnToken)
        canceledTurnDrainTask?.cancel()
        canceledTurnDrainTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            await self?.finishCanceledTurnDrainIfNeeded()
        }
        _ = try? await sendRPC(.turnInterrupt(id: allocRpcId(), threadId: tid))
    }

    func disconnect() async {
        routerTask?.cancel()
        routerTask = nil
        await transport?.close()
        transport = nil
    }

    // MARK: - JSON-RPC

    private func allocRpcId() -> Int {
        let id = nextRpcId
        nextRpcId += 1
        return id
    }

    /// 发送 RPC 请求并通过共享迭代器等待响应（用于 connect 阶段）。
    private func sendRPCWithIterator(
        _ request: CodexRPCRequest,
        iterator: inout AsyncThrowingStream<String, Error>.AsyncIterator
    ) async throws -> CodexRPCResponse {
        guard let transport else { throw ACPConnectionError.notConnected }

        let data = try JSONEncoder().encode(request)
        guard let json = String(data: data, encoding: .utf8) else {
            throw ACPTransportError.encodingFailed
        }
        try await transport.writeLine(json)

        let decoder = JSONDecoder()
        let expectedId = request.id

        while let line = try await iterator.next() {
            guard line.hasPrefix("{"),
                  let lineData = line.data(using: .utf8) else { continue }

            guard let msg = try? decoder.decode(CodexRPCMessage.self, from: lineData) else {
                continue
            }

            switch msg {
            case .response(let resp) where resp.id == expectedId:
                return resp
            case .response:
                // 非预期的响应，忽略
                continue
            case .notification:
                // 握手阶段的通知，忽略
                continue
            }
        }

        let diag = transport.diagnosticLog.summary
        let suffix = diag.isEmpty ? "" : " Diagnostics: \(diag)"
        throw ACPConnectionError.protocolError("Codex exited without responding to RPC id=\(expectedId).\(suffix)")
    }

    /// 发送 RPC 请求并等待响应（消息路由已启动后使用）。
    private func sendRPC(_ request: CodexRPCRequest) async throws -> CodexRPCResponse {
        guard let transport else { throw ACPConnectionError.notConnected }

        let id = request.id
        let data = try JSONEncoder().encode(request)
        guard let json = String(data: data, encoding: .utf8) else {
            throw ACPTransportError.encodingFailed
        }
        let buffer = BufferedResponseBuffer<CodexRPCResponse>()
        pendingRPC[id] = buffer

        Task { [weak self] in
            try? await Task.sleep(for: .seconds(120))
            await self?.timeoutRPC(id: id)
        }

        do {
            try await transport.writeLine(json)
        } catch {
            pendingRPC.removeValue(forKey: id)
            await buffer.fail(error)
        }

        return try await buffer.wait()
    }

    private func timeoutRPC(id: Int) async {
        if let buffer = pendingRPC.removeValue(forKey: id) {
            await buffer.fail(ACPConnectionError.timeout)
        }
    }

    // MARK: - 消息路由

    /// 启动消息路由（从共享迭代器继续消费）。
    private func startMessageRouter() {
        guard var iterator = lineIterator else { return }
        let decoder = JSONDecoder()

        routerTask = Task { [weak self] in
            do {
                while let line = try await iterator.next() {
                    guard let self else { return }
                    guard line.hasPrefix("{"),
                          let data = line.data(using: .utf8) else { continue }

                    guard let msg = try? decoder.decode(CodexRPCMessage.self, from: data) else {
                        continue
                    }

                    await self.handleMessage(msg)
                }
                // 流结束 = 进程退出
                await self?.handleDisconnect()
            } catch {
                await self?.handleDisconnect()
            }
        }
    }

    /// 处理单条消息。
    private func handleMessage(_ msg: CodexRPCMessage) async {
        switch msg {
        case .response(let resp):
            if let buffer = pendingRPC.removeValue(forKey: resp.id) {
                await buffer.succeed(resp)
            }

        case .notification(let notif):
            await handleNotification(notif)
        }
    }

    /// 处理通知消息，翻译为 SessionUpdate。
    private func handleNotification(_ notif: CodexNotification) async {
        switch notif.method {
        case "item/started":
            guard let item = try? notif.decodeItemParams() else { return }
            if let update = CodexMessageTranslator.translateItemStarted(item) {
                updateHandler?(update)
            }

        case "item/completed":
            guard let item = try? notif.decodeItemParams() else { return }
            if let update = CodexMessageTranslator.translateItemCompleted(item) {
                updateHandler?(update)
            }

        case "item/agentMessage/delta":
            guard let delta = try? notif.decodeDelta(), !delta.isEmpty else { return }
            let update = CodexMessageTranslator.translateDelta(delta)
            updateHandler?(update)

        case "turn/completed":
            if isDrainingCanceledTurn {
                isDrainingCanceledTurn = false
                canceledTurnDrainTask?.cancel()
                canceledTurnDrainTask = nil
                await canceledTurnDrainSignal.succeed()
                return
            }
            let turnToken = await turnCompletionSignal.activeTurnToken()
            if turnToken > 0 {
                await turnCompletionSignal.succeed(for: turnToken)
            }

        case "thread/tokenUsage/updated", "account/rateLimits/updated",
             "thread/started", "thread/status/changed", "turn/started":
            // 信息性通知，静默忽略
            break

        default:
            #if DEBUG
            print("[CodexConnection] Unknown notification: \(notif.method)")
            #endif
        }
    }

    /// 处理断开连接。
    private func handleDisconnect() async {
        if isDrainingCanceledTurn {
            isDrainingCanceledTurn = false
            canceledTurnDrainTask?.cancel()
            canceledTurnDrainTask = nil
            await canceledTurnDrainSignal.fail(ACPConnectionError.disconnected)
        }
        let turnToken = await turnCompletionSignal.activeTurnToken()
        if turnToken > 0 {
            await turnCompletionSignal.fail(ACPConnectionError.disconnected, for: turnToken)
        }
        for (_, buffer) in pendingRPC {
            await buffer.fail(ACPConnectionError.disconnected)
        }
        pendingRPC.removeAll()
        disconnectHandler?()
    }

    private func finishCanceledTurnDrainIfNeeded() async {
        guard isDrainingCanceledTurn else { return }
        isDrainingCanceledTurn = false
        canceledTurnDrainTask = nil
        await canceledTurnDrainSignal.succeed()
    }

    // MARK: - Model / Mode 解析

    /// 从 model/list 响应解析 ModelsInfo。
    /// Codex 返回格式：{ data: [{ id, displayName, description, isDefault, ... }] }
    private static func parseModelsInfo(from response: CodexRPCResponse) -> ModelsInfo? {
        guard let result = response.result,
              case .object(let obj) = result,
              case .array(let dataArr) = obj["data"] else { return nil }

        var models: [ModelInfo] = []
        var currentModelId = ""

        for item in dataArr {
            guard case .object(let modelObj) = item,
                  case .string(let id) = modelObj["id"] else { continue }
            let displayName: String
            if case .string(let name) = modelObj["displayName"] { displayName = name }
            else { displayName = id }
            let description: String?
            if case .string(let desc) = modelObj["description"] { description = desc }
            else { description = nil }

            models.append(ModelInfo(modelId: id, name: displayName, description: description))

            // isDefault 标记当前模型
            if case .bool(let isDefault) = modelObj["isDefault"], isDefault {
                currentModelId = id
            }
        }

        guard !models.isEmpty else { return nil }
        if currentModelId.isEmpty { currentModelId = models[0].modelId }
        return ModelsInfo(currentModelId: currentModelId, availableModels: models)
    }

    /// 从 collaborationMode/list 响应解析 ModesInfo。
    /// Codex 返回格式：{ data: [{ name, mode, ... }] }
    private static func parseModesInfo(from response: CodexRPCResponse) -> ModesInfo? {
        guard let result = response.result,
              case .object(let obj) = result,
              case .array(let dataArr) = obj["data"] else { return nil }

        var modes: [ModeInfo] = []
        let currentModeId = "default"

        for item in dataArr {
            guard case .object(let modeObj) = item,
                  case .string(let mode) = modeObj["mode"] else { continue }
            let name: String
            if case .string(let n) = modeObj["name"] { name = n }
            else { name = mode }
            modes.append(ModeInfo(id: mode, name: name))
        }

        guard !modes.isEmpty else { return nil }
        return ModesInfo(currentModeId: currentModeId, availableModes: modes)
    }

    // MARK: - Model / Mode 切换

    /// 待发送的 model（下次 turn/start 时生效）。
    private var pendingModel: String?

    /// 设置 model（Codex 的 model 切换通过 turn/start 参数传递，不是独立 RPC）。
    func setModel(modelId: String) {
        pendingModel = modelId
        if let modelsInfo {
            self.modelsInfo = ModelsInfo(
                currentModelId: modelId,
                availableModels: modelsInfo.availableModels
            )
        }
    }

    /// 待发送的 mode（下次 turn/start 时生效）。
    private var pendingMode: String?

    /// 设置 mode（同 model，通过 turn/start 参数传递）。
    func setMode(modeId: String) {
        pendingMode = modeId
        if let modesInfo {
            self.modesInfo = ModesInfo(
                currentModeId: modeId,
                availableModes: modesInfo.availableModes
            )
        }
    }

    // MARK: - Skills

    /// 可用的 skills（转换为 AvailableCommand 供 UI 展示）。
    private(set) var availableCommands: [AvailableCommand] = []

    /// 从 skills/list 响应解析 AvailableCommand 列表。
    /// Codex 返回格式：{ data: [{ cwd, skills: [{ name, description, shortDescription, ... }] }] }
    private static func parseSkillsAsCommands(from response: CodexRPCResponse) -> [AvailableCommand] {
        guard let result = response.result,
              case .object(let obj) = result,
              case .array(let dataArr) = obj["data"] else { return [] }

        var commands: [AvailableCommand] = []
        for item in dataArr {
            guard case .object(let cwdObj) = item,
                  case .array(let skills) = cwdObj["skills"] else { continue }
            for skill in skills {
                guard case .object(let skillObj) = skill,
                      case .string(let name) = skillObj["name"] else { continue }
                // 优先用 shortDescription，fallback 到 description
                let desc: String
                if case .string(let sd) = skillObj["shortDescription"], !sd.isEmpty {
                    desc = sd
                } else if case .string(let d) = skillObj["description"] {
                    desc = String(d.prefix(100))
                } else {
                    desc = name
                }
                commands.append(AvailableCommand(name: name, description: desc))
            }
        }
        return commands
    }
}
