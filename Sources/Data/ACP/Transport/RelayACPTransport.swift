/// 文件说明：RelayACPTransport，通过 relay WebSocket 通道传输 ACP JSON-RPC 消息。
/// 替代 SSHACPTransport，用于 DLC relay 模式。

import Foundation
@preconcurrency import ACPModel

/// RelayACPTransport：通过 relay 通道与远端 ACP 代理进行双向 ND-JSON 通信。
/// relay 链路：iOS → WebSocket → DO → daemon → agent 进程 stdin/stdout
actor RelayACPTransport: ACPTransport {
    private let relayConnection: RelayConnection
    private let agentCommand: String
    private let cwd: String
    private let sessionID: String

    private let messageContinuation: AsyncThrowingStream<ACPMessage, Error>.Continuation
    nonisolated let messages: AsyncThrowingStream<ACPMessage, Error>

    private var isStarted = false
    private var eventTask: Task<Void, Never>?

    init(relayConnection: RelayConnection, agentCommand: String, cwd: String) {
        self.relayConnection = relayConnection
        self.agentCommand = agentCommand
        self.cwd = cwd
        self.sessionID = UUID().uuidString
        let (stream, continuation) = AsyncThrowingStream<ACPMessage, Error>.makeStream()
        self.messages = stream
        self.messageContinuation = continuation
    }

    func start() async throws {
        guard !isStarted else { return }
        isStarted = true

        // 发送 acp_start 给 daemon（通过 relay）
        try await relayConnection.sendACPStart(
            sessionID: sessionID,
            command: agentCommand,
            cwd: cwd
        )

        // 监听 relay 事件流中的 ACP 数据
        startEventConsumption()
    }

    func send(_ message: ACPMessage) async throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = []
        let data = try encoder.encode(message)
        guard let jsonString = String(data: data, encoding: .utf8) else {
            throw RelayError.networkError("Failed to encode ACP message")
        }
        // 发送到 daemon stdin
        try await relayConnection.sendACPData(sessionID: sessionID, data: jsonString + "\n")
    }

    func close() async {
        eventTask?.cancel()
        eventTask = nil
        try? await relayConnection.sendACPClose(sessionID: sessionID)
        messageContinuation.finish()
    }

    private func startEventConsumption() {
        eventTask = Task { [weak self, relayConnection] in
            for await event in relayConnection.events {
                guard let self else { break }
                await self.handleEvent(event)
            }
        }
    }

    private func handleEvent(_ event: RelayEvent) {
        switch event {
        case .acpData(let sid, _, let data):
            guard sid == sessionID else { return }
            // 解析 ND-JSON 行为 ACPMessage
            for line in data.components(separatedBy: "\n") where !line.isEmpty {
                guard let lineData = line.data(using: .utf8) else { continue }
                do {
                    let message = try JSONDecoder().decode(ACPMessage.self, from: lineData)
                    messageContinuation.yield(message)
                } catch {
                    // 非 JSON 行（代理启动噪声），忽略
                }
            }
        case .acpClosed(let sid):
            guard sid == sessionID else { return }
            messageContinuation.finish()
        case .acpError(let sid, let error):
            guard sid == sessionID else { return }
            messageContinuation.finish(throwing: RelayError.networkError(error))
        case .disconnected:
            messageContinuation.finish(throwing: RelayError.networkError("Relay disconnected"))
        default:
            break
        }
    }
}
