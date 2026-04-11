/// 文件说明：ACPClientConnection，管理与远端 ACP 代理的连接、会话和消息路由。

import Foundation
@preconcurrency import ACPModel

/// SessionNewRequestPayload：
/// `session/new` 的请求参数。为兼容新版 ACP CLI，显式携带 `mcpServers`。
nonisolated struct SessionNewRequestPayload: Encodable, Sendable {
    /// 会话工作目录（必须为绝对路径）。
    let cwd: String
    /// 兼容字段：显式声明 MCP server 列表；默认空数组表示不注入额外 MCP。
    let mcpServers: [String]

    init(cwd: String, mcpServers: [String] = []) {
        self.cwd = cwd
        self.mcpServers = mcpServers
    }
}

/// ACPClientConnection：管理与远端 ACP 代理的完整生命周期。
/// 负责初始化握手、Session 管理、请求/响应 ID 匹配、通知分发。
actor ACPClientConnection {
    private let transport: ACPTransport
    private let requestTimeoutSeconds: TimeInterval

    private var nextRequestId: Int = 1
    private var pendingRequests: [String: CheckedContinuation<AnyCodable?, Error>] = [:]
    private var messageRouterTask: Task<Void, Never>?

    private(set) var agentInfo: ACPModel.AgentInfo?
    private(set) var agentCapabilities: AgentCapabilities?

    /// 会话更新回调：代理发送流式更新时调用。
    var sessionUpdateHandler: (@Sendable (SessionUpdate) -> Void)?

    /// 权限请求回调：代理请求用户审批时调用。
    var permissionRequestHandler: (@Sendable (ACPPermissionRequest) async -> Bool)?

    func setUpdateHandler(_ handler: @escaping @Sendable (SessionUpdate) -> Void) {
        sessionUpdateHandler = handler
    }

    func setPermissionHandler(_ handler: @escaping @Sendable (ACPPermissionRequest) async -> Bool) {
        permissionRequestHandler = handler
    }

    init(transport: ACPTransport, requestTimeoutSeconds: TimeInterval = 120) {
        self.transport = transport
        self.requestTimeoutSeconds = requestTimeoutSeconds
    }

    // MARK: - 生命周期

    /// 连接到代理并完成初始化握手。
    func connect() async throws -> InitializeResponse {
        try await transport.start()
        startMessageRouter()

        let params = InitializeRequest(
            protocolVersion: 1,
            clientCapabilities: ClientCapabilities(
                fs: FileSystemCapabilities(readTextFile: true, writeTextFile: true),
                terminal: true
            ),
            clientInfo: ClientInfo(name: "ConchTalk", version: "1.0.0")
        )

        guard let resultValue = try await sendRequest(method: "initialize", params: params) else {
            throw ACPConnectionError.protocolError("Initialize returned nil result")
        }

        let data = try JSONEncoder().encode(resultValue)
        let result = try JSONDecoder().decode(InitializeResponse.self, from: data)

        agentInfo = result.agentInfo
        agentCapabilities = result.agentCapabilities
        return result
    }

    /// 断开连接，清理所有资源。
    func disconnect() async {
        messageRouterTask?.cancel()
        messageRouterTask = nil

        for (_, continuation) in pendingRequests {
            continuation.resume(throwing: ACPConnectionError.disconnected)
        }
        pendingRequests.removeAll()

        await transport.close()
    }

    // MARK: - Session 操作

    /// 创建新会话。
    /// cwd 必须是已解析的绝对路径（`~` 和 `$HOME` 不会被远端 shell 展开）。
    func createSession(cwd: String) async throws -> NewSessionResponse {
        let params = SessionNewRequestPayload(cwd: cwd)
        guard let resultValue = try await sendRequest(method: "session/new", params: params) else {
            throw ACPConnectionError.protocolError("session/new returned nil result")
        }
        
        let data = try JSONEncoder().encode(resultValue)
        return try JSONDecoder().decode(NewSessionResponse.self, from: data)
    }

    /// 发送 prompt 并等待完成。
    func prompt(sessionId: SessionId, text: String) async throws -> SessionPromptResponse {
        let params = SessionPromptRequest(
            sessionId: sessionId,
            prompt: [.text(TextContent(text: text))]
        )
        guard let resultValue = try await sendRequest(method: "session/prompt", params: params) else {
            throw ACPConnectionError.protocolError("session/prompt returned nil result")
        }
        let data = try JSONEncoder().encode(resultValue)
        return try JSONDecoder().decode(SessionPromptResponse.self, from: data)
    }

    /// 取消当前 prompt 执行。
    func cancelPrompt(sessionId: SessionId) async throws {
        let params = CancelSessionRequest(sessionId: sessionId)
        let paramsValue = try encodeToAnyCodable(params)
        let notification = ACPMessage.notification(JSONRPCNotification(
            method: "session/cancel",
            params: paramsValue
        ))
        try await transport.send(notification)
    }

    // MARK: - Config

    /// 设置 session config option（走 session/set_config_option RPC）。
    func setConfigOption(sessionId: SessionId, configId: SessionConfigId, value: SessionConfigOptionValue) async throws {
        let params = SetSessionConfigOptionRequest(
            sessionId: sessionId,
            configId: configId,
            value: value
        )
        _ = try await sendRequest(method: "session/set_config_option", params: params)
    }

    /// 切换 model（走 session/set_model RPC）。
    func setModel(sessionId: SessionId, modelId: String) async throws {
        let params = SetModelRequest(sessionId: sessionId, modelId: modelId)
        _ = try await sendRequest(method: "session/set_model", params: params)
    }

    /// 切换 mode（走 session/set_mode RPC）。
    func setMode(sessionId: SessionId, modeId: String) async throws {
        let params = SetModeRequest(sessionId: sessionId, modeId: modeId)
        _ = try await sendRequest(method: "session/set_mode", params: params)
    }

    // MARK: - 内部

    /// 启动消息路由后台 Task。
    private func startMessageRouter() {
        let transport = self.transport
        messageRouterTask = Task { [weak self] in
            guard self != nil else { return }
            do {
                for try await message in transport.messages {
                    await self?.routeMessage(message)
                }
                // 消息流正常结束 — 代理进程退出或 SSH 通道关闭
                print("[ACPClientConnection] Message stream ended (agent exited)")
                await self?.handleTransportClosed()
            } catch {
                print("[ACPClientConnection] Message router error: \(error)")
                await self?.handleTransportError(error)
            }
        }
    }

    /// 路由单条消息到对应处理器。
    private func routeMessage(_ message: ACPMessage) {
        #if DEBUG
        switch message {
        case .response(let resp):
            print("[ACP:Router] Response id=\(resp.id), hasError=\(resp.error != nil)")
        case .notification(let notif):
            print("[ACP:Router] Notification method=\(notif.method)")
        case .request(let req):
            print("[ACP:Router] Request id=\(req.id) method=\(req.method)")
        }
        #endif

        switch message {
        case .response(let response):
            let key = response.id.description
            guard let continuation = pendingRequests.removeValue(forKey: key) else {
                print("[ACPClientConnection] No pending request for response id: \(key)")
                return
            }
            if let error = response.error {
                // 包含 error.data 以提供更详细的诊断信息
                var detail = "Agent error \(error.code): \(error.message)"
                if let data = error.data {
                    if let dataStr = try? String(data: JSONEncoder().encode(data), encoding: .utf8) {
                        detail += " | data: \(dataStr)"
                    }
                }
                continuation.resume(throwing: ACPConnectionError.protocolError(detail))
            } else {
                continuation.resume(returning: response.result)
            }

        case .notification(let notification):
            handleNotification(method: notification.method, params: notification.params)

        case .request(let request):
            handleAgentRequest(id: request.id, method: request.method, params: request.params)
        }
    }

    /// 处理代理发来的通知。
    private func handleNotification(method: String, params: AnyCodable?) {
        guard method == "session/update", let params else { return }
        do {
            let data = try JSONEncoder().encode(params)
            // 优先尝试 ACPModel 标准解码
            do {
                let notification = try JSONDecoder().decode(SessionUpdateNotification.self, from: data)
                sessionUpdateHandler?(notification.update)
                return
            } catch {
                #if DEBUG
                print("[ACPClientConnection] Standard decode failed: \(error)")
                #endif
            }
            // Fallback：处理非标准 update 类型（thinking_chunk, text_chunk, turn_complete, end_turn 等）
            // 以及标准类型但 ContentBlock 解码失败的情况（如未知 content type）
            if let fallbackUpdate = Self.decodeFallbackUpdate(from: data) {
                sessionUpdateHandler?(fallbackUpdate)
            } else {
                #if DEBUG
                let preview = String(data: data, encoding: .utf8)?.prefix(300) ?? "nil"
                print("[ACPClientConnection] Failed to decode session/update, raw: \(preview)")
                #endif
            }
        } catch {
            print("[ACPClientConnection] Failed to encode session/update params: \(error)")
        }
    }

    /// Fallback 解码：处理 ACPModel SessionUpdate 不支持的非标准 update 类型，
    /// 以及标准类型因 ContentBlock 解码失败而需要降级处理的情况。
    private static func decodeFallbackUpdate(from data: Data) -> SessionUpdate? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let updateDict = json["update"] as? [String: Any],
              let updateType = updateDict["sessionUpdate"] as? String else {
            return nil
        }

        // 从 update dict 直接提取文本（非标准格式）
        let directText = updateDict["text"] as? String ?? ""
        // 从 content block 提取文本（标准格式，ContentBlock 类型未知时手动解析）
        let contentText: String = {
            guard let content = updateDict["content"] as? [String: Any] else { return "" }
            return content["text"] as? String ?? ""
        }()
        let text = directText.isEmpty ? contentText : directText

        switch updateType {
        // 非标准类型（部分代理的扩展格式）
        case "thinking_chunk", "thinking":
            return .agentThoughtChunk(.text(TextContent(text: text)))
        case "text_chunk", "text":
            return .agentMessageChunk(.text(TextContent(text: text)))
        case "turn_complete", "end_turn":
            // prompt() 返回来表示完成，这里静默忽略
            return nil
        case "tool_result":
            let name = (updateDict["toolCall"] as? [String: Any])?["name"] as? String ?? "tool"
            let result = (updateDict["toolCall"] as? [String: Any])?["result"] as? String ?? ""
            return .toolCallUpdate(ToolCallUpdateDetails(
                toolCallId: name,
                status: .completed,
                content: result.isEmpty ? nil : [.content(.text(TextContent(text: result)))]
            ))
        // 标准类型（ContentBlock 解码失败时的降级路径）
        case "agent_message_chunk":
            guard !text.isEmpty else { return nil }
            return .agentMessageChunk(.text(TextContent(text: text)))
        case "agent_thought_chunk":
            guard !text.isEmpty else { return nil }
            return .agentThoughtChunk(.text(TextContent(text: text)))
        // 已知可忽略的标准类型
        case "usage_update", "session_info_update", "config_option_update",
             "available_commands_update", "current_mode_update":
            return nil
        default:
            print("[ACPClientConnection] Unknown update type: \(updateType)")
            return nil
        }
    }

    /// 处理代理发来的请求（如权限请求）。
    private func handleAgentRequest(id: ACPModel.RequestId, method: String, params: AnyCodable?) {
        Task {
            switch method {
            case "session/request_permission":
                guard let params else {
                    try? await sendResponse(id: id, result: AnyCodable(false))
                    return
                }
                do {
                    let data = try JSONEncoder().encode(params)
                    let request = try JSONDecoder().decode(ACPPermissionRequest.self, from: data)
                    let approved = await permissionRequestHandler?(request) ?? false
                    try? await sendResponse(id: id, result: AnyCodable(approved))
                } catch {
                    print("[ACPClientConnection] Failed to decode permission request: \(error)")
                    try? await sendResponse(id: id, result: AnyCodable(false))
                }
            default:
                let errorResponse = ACPMessage.response(JSONRPCResponse(
                    id: id,
                    result: nil,
                    error: JSONRPCError(code: -32601, message: "Method not found: \(method)", data: nil)
                ))
                try? await transport.send(errorResponse)
            }
        }
    }

    /// transport 错误时取消所有等待中的请求。
    private func handleTransportError(_ error: Error) {
        for (_, continuation) in pendingRequests {
            continuation.resume(throwing: error)
        }
        pendingRequests.removeAll()
    }

    /// transport 消息流正常结束时（代理进程退出/SSH 通道关闭）的清理。
    /// 将所有 pending 请求以 disconnected 错误恢复，避免挂到超时。
    private func handleTransportClosed() {
        let pendingCount = pendingRequests.count
        if pendingCount > 0 {
            print("[ACPClientConnection] Transport closed with \(pendingCount) pending request(s)")
        }
        for (_, continuation) in pendingRequests {
            continuation.resume(throwing: ACPConnectionError.disconnected)
        }
        pendingRequests.removeAll()
    }

    /// 发送请求并等待响应，带超时。
    private func sendRequest<P: Encodable>(method: String, params: P) async throws -> AnyCodable? {
        #if DEBUG
        print("[ACP:Send] method=\(method), pendingCount=\(pendingRequests.count)")
        #endif
        let id = ACPModel.RequestId.number(nextRequestId)
        nextRequestId += 1
        let key = id.description

        let paramsValue = try encodeToAnyCodable(params)
        let message = ACPMessage.request(JSONRPCRequest(id: id, method: method, params: paramsValue))

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<AnyCodable?, Error>) in
            self.pendingRequests[key] = continuation

            Task { [weak self] in
                try? await Task.sleep(for: .seconds(self?.requestTimeoutSeconds ?? 120))
                await self?.timeoutRequest(key: key)
            }

            Task { [weak self] in
                do {
                    try await self?.transport.send(message)
                } catch {
                    await self?.failPendingRequest(key: key, error: error)
                }
            }
        }
    }

    /// 超时取消指定请求。
    private func timeoutRequest(key: String) {
        if let cont = pendingRequests.removeValue(forKey: key) {
            cont.resume(throwing: ACPConnectionError.timeout)
        }
    }

    /// 发送失败时恢复对应 pending request，避免无响应悬挂。
    private func failPendingRequest(key: String, error: Error) {
        if let cont = pendingRequests.removeValue(forKey: key) {
            cont.resume(throwing: error)
        }
    }

    /// 发送响应消息。
    private func sendResponse(id: ACPModel.RequestId, result: AnyCodable?) async throws {
        let message = ACPMessage.response(JSONRPCResponse(id: id, result: result, error: nil))
        try await transport.send(message)
    }

    /// 将 Encodable 值转换为 AnyCodable。
    private func encodeToAnyCodable<T: Encodable>(_ value: T) throws -> AnyCodable {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(AnyCodable.self, from: data)
    }
}

/// ACPPermissionRequest：代理发送的权限请求（ACPModel 未定义独立类型，保留自定义）。
nonisolated struct ACPPermissionRequest: Codable, Sendable {
    let description: String
    let tool: String?
    let arguments: AnyCodable?
}

/// ACPConnectionError：ACP 连接层错误。
nonisolated enum ACPConnectionError: LocalizedError, Sendable {
    case notConnected
    case connectionRejected(String)
    case timeout
    case protocolError(String)
    case disconnected

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "ACP transport not connected"
        case .connectionRejected(let reason):
            return "Agent rejected connection: \(reason)"
        case .timeout:
            return "ACP request timed out"
        case .protocolError(let detail):
            return "ACP protocol error: \(detail)"
        case .disconnected:
            return "ACP connection lost"
        }
    }
}
