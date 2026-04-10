/// 文件说明：RelayConnection，负责与 relay DO 的 WebSocket 连接管理。
/// 使用 AsyncStream 事件模式，与 DirectSessionCoordinator 一致。
import Foundation

/// Daemon 上报的 CPU/内存使用率（小数，0-1）。
struct RelayMetrics: Sendable {
    let cpu: Double
    let memory: Double
}

/// RelayConnection：管理与 relay 服务器的 WebSocket 连接。
actor RelayConnection {
    private let serverID: UUID
    private let authService: AuthServiceProtocol
    private var webSocket: URLSessionWebSocketTask?
    private var heartbeatTask: Task<Void, Never>?
    private var receiveTask: Task<Void, Never>?
    private(set) var isConnected: Bool = false
    private(set) var isDaemonOnline: Bool = false
    /// 最近一次收到的 daemon metrics。
    private(set) var latestMetrics: RelayMetrics?

    /// 事件流，供外部（ChatViewModel）消费。
    let events: AsyncStream<RelayEvent>
    private let eventContinuation: AsyncStream<RelayEvent>.Continuation

    private let baseURL = "wss://api.conch-talk.com"

    init(serverID: UUID, authService: AuthServiceProtocol) {
        self.serverID = serverID
        self.authService = authService
        let (stream, continuation) = AsyncStream.makeStream(of: RelayEvent.self)
        self.events = stream
        self.eventContinuation = continuation
    }

    func connect() async throws {
        // 幂等：已连接时直接返回，避免重复创建 WebSocket
        guard !isConnected else { return }

        // 获取有效 access token
        let token = try await authService.validAccessToken()

        var components = URLComponents(string: "\(baseURL)/relay")!
        components.queryItems = [
            URLQueryItem(name: "role", value: "client"),
            URLQueryItem(name: "server_id", value: serverID.uuidString),
        ]

        guard let url = components.url else {
            throw RelayError.networkError("Invalid URL")
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let session = URLSession(configuration: .default)
        let ws = session.webSocketTask(with: request)
        ws.resume()

        self.webSocket = ws
        // 不立即标记 isConnected：等 receive loop 收到第一条消息后再确认连接成功，
        // 避免握手/认证失败时短暂误报已连接。

        startReceiveLoop()
        startHeartbeat()
    }

    func disconnect() {
        heartbeatTask?.cancel()
        receiveTask?.cancel()
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        isConnected = false
        isDaemonOnline = false
        eventContinuation.yield(.disconnected)
    }

    func sendUserMessage(_ content: String) async throws {
        try await send(["type": "user_message", "content": content])
    }

    func sendApproval(taskId: String, approved: Bool) async throws {
        try await send(["type": "approve", "task_id": taskId, "approved": approved] as [String: Any])
    }

    func sendCancel() async throws {
        try await send(["type": "cancel"])
    }

    func sendToolExec(id: String, tool: String, arguments: [String: Any]) async throws {
        try await send([
            "type": "tool_exec",
            "id": id,
            "tool": tool,
            "arguments": arguments,
        ] as [String: Any])
    }

    func sendClearConversation() async throws {
        try await send(["type": "clear_conversation"])
    }

    // MARK: - ACP

    func sendACPStart(sessionID: String, command: String, cwd: String) async throws {
        try await send([
            "type": "acp_start",
            "session_id": sessionID,
            "command": command,
            "cwd": cwd,
        ] as [String: Any])
    }

    func sendACPData(sessionID: String, data: String) async throws {
        try await send([
            "type": "acp_data",
            "session_id": sessionID,
            "data": data,
        ] as [String: Any])
    }

    func sendACPClose(sessionID: String) async throws {
        try await send([
            "type": "acp_close",
            "session_id": sessionID,
        ] as [String: Any])
    }

    func sendGetCapabilities() async throws {
        try await send(["type": "get_capabilities"])
    }

    // MARK: - Private

    private func send(_ dict: [String: Any]) async throws {
        guard let ws = webSocket else { throw RelayError.networkError("Not connected") }
        let data = try JSONSerialization.data(withJSONObject: dict)
        let str = String(data: data, encoding: .utf8)!
        try await ws.send(.string(str))
    }

    private func startReceiveLoop() {
        receiveTask = Task { [weak self] in
            var confirmedConnected = false
            while !Task.isCancelled {
                guard let self else { break }
                guard let ws = await self.webSocket else { break }
                do {
                    let message = try await ws.receive()
                    // 首次成功接收消息：握手和认证已通过，确认连接
                    if !confirmedConnected {
                        confirmedConnected = true
                        await self.confirmConnected()
                    }
                    switch message {
                    case .string(let text):
                        guard let data = text.data(using: .utf8) else { continue }
                        if let event = RelayMessage.parse(from: data) {
                            await self.processEvent(event)
                        }
                    case .data(let data):
                        if let event = RelayMessage.parse(from: data) {
                            await self.yieldEvent(event)
                        }
                    @unknown default:
                        break
                    }
                } catch {
                    await self.handleDisconnect()
                    break
                }
            }
        }
    }

    private func processEvent(_ event: RelayEvent) {
        if case .daemonStatus(let online) = event {
            isDaemonOnline = online
        }
        if case .metrics(let cpu, let memory) = event {
            print("[Relay] raw metrics: cpu=\(cpu) memory=\(memory)")
            latestMetrics = RelayMetrics(cpu: cpu, memory: memory)
        }
        eventContinuation.yield(event)
    }

    private func yieldEvent(_ event: RelayEvent) {
        eventContinuation.yield(event)
    }

    private func startHeartbeat() {
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(25))
                guard !Task.isCancelled, let self else { break }
                do {
                    try await self.send(["type": "ping"])
                } catch {
                    await self.handleDisconnect()
                    break
                }
            }
        }
    }

    /// 首次成功接收消息后确认连接（握手和认证已通过）。
    private func confirmConnected() {
        isConnected = true
        eventContinuation.yield(.connected)
    }

    private func handleDisconnect() {
        isConnected = false
        isDaemonOnline = false
        eventContinuation.yield(.disconnected)
    }
}
