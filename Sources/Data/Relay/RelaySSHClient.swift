/// 文件说明：RelaySSHClient，通过 WebSocket Relay 中继实现 SSHClientProtocol。
import Foundation

/// RelaySSHClient：
/// 将 SSHClientProtocol 的命令执行与 SFTP 操作转发给远端 Daemon，
/// 通过 RelayConnection WebSocket 通道收发 tool_exec / toolDone / toolError 消息。
/// 不直接消费 RelayConnection.events（单消费者限制），而是由外部（ChatViewModel）
/// 转发相关事件到 handleEvent(_:)。
actor RelaySSHClient: SSHClientProtocol {
    private let relay: RelayConnection
    private let _serverID: UUID
    private let defaultTimeout: TimeInterval = 120

    /// 等待 toolDone/toolError 响应的续体映射表（callID → continuation）。
    private var pendingCalls: [String: CheckedContinuation<ToolExecResult, Error>] = [:]
    /// 流式调用的续体映射表（callID → stream continuation）。
    private var pendingStreams: [String: AsyncThrowingStream<String, Error>.Continuation] = [:]

    /// tool_exec 执行结果。
    private struct ToolExecResult: Sendable {
        let exitCode: Int
        let output: String
    }

    init(relay: RelayConnection, serverID: UUID) {
        self.relay = relay
        self._serverID = serverID
    }

    // MARK: - SSHClientProtocol

    nonisolated var serverID: UUID? {
        get async { _serverID }
    }

    nonisolated var isConnected: Bool {
        get async {
            let relayConnected = await relay.isConnected
            let daemonOnline = await relay.isDaemonOnline
            return relayConnected && daemonOnline
        }
    }

    nonisolated var serverCapabilities: ServerCapabilities {
        get async { .unknown }
    }

    func connect(to server: Server, password: String?, sshKeyData: Data?, keyPassphrase: String?) async throws {
        // 连接生命周期由 RelayConnection 管理，此处为空操作
    }

    func disconnect() async {
        // 连接生命周期由 RelayConnection 管理，此处为空操作
    }

    func execute(command: String, timeout: TimeInterval) async throws -> String {
        let callID = UUID().uuidString

        let result = try await sendAndWait(callID: callID, timeout: timeout) {
            try await self.relay.sendToolExec(
                id: callID,
                tool: "execute_command",
                arguments: ["command": command]
            )
        }

        if result.exitCode != 0 && result.output.isEmpty {
            throw SSHError.commandFailed("Command exited with code \(result.exitCode)")
        }
        return result.output
    }

    nonisolated func executeStreaming(command: String) -> AsyncThrowingStream<String, Error> {
        let callID = UUID().uuidString

        return AsyncThrowingStream { continuation in
            Task {
                // 先注册流式续体再发送，toolDone/toolError 由 handleEvent 直接 finish stream
                await self.registerStream(callID: callID, continuation: continuation)

                continuation.onTermination = { @Sendable _ in
                    Task { await self.cleanupStream(callID: callID) }
                }

                do {
                    try await self.relay.sendToolExec(
                        id: callID,
                        tool: "execute_command",
                        arguments: ["command": command]
                    )
                } catch {
                    await self.cleanupStream(callID: callID)
                    continuation.finish(throwing: error)
                }
                // stream 的 finish 由 handleEvent 中的 toolDone/toolError 触发
            }
        }
    }

    /// 注册流式续体到映射表。
    private func registerStream(callID: String, continuation: AsyncThrowingStream<String, Error>.Continuation) {
        pendingStreams[callID] = continuation
    }

    // MARK: - SFTP

    func sftpReadFile(path: String) async throws -> Data {
        let callID = UUID().uuidString

        let result = try await sendAndWait(callID: callID, timeout: defaultTimeout) {
            try await self.relay.sendToolExec(
                id: callID,
                tool: "read_file",
                arguments: ["path": path]
            )
        }

        // Daemon 返回的内容可能是 base64 编码，也可能是纯文本
        if let data = Data(base64Encoded: result.output) {
            return data
        }
        return Data(result.output.utf8)
    }

    func sftpWriteFile(path: String, data: Data) async throws {
        let callID = UUID().uuidString
        let base64Content = data.base64EncodedString()

        let result = try await sendAndWait(callID: callID, timeout: defaultTimeout) {
            try await self.relay.sendToolExec(
                id: callID,
                tool: "write_file",
                arguments: ["path": path, "content": base64Content, "encoding": "base64"]
            )
        }

        if result.exitCode != 0 {
            throw SSHError.commandFailed("Failed to write file: \(result.output)")
        }
    }

    func sftpFileSize(path: String) async throws -> UInt64 {
        // 使用 stat 命令探测文件大小（兼容 Linux 和 macOS）
        let command = "stat -c %s \(path) 2>/dev/null || stat -f %z \(path)"
        let output = try await execute(command: command, timeout: 30)
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let size = UInt64(trimmed) else {
            throw SSHError.commandFailed("Cannot parse file size: \(trimmed)")
        }
        return size
    }

    func sftpWriteFileChunked(
        path: String,
        data: Data,
        chunkSize: Int,
        onProgress: @escaping @Sendable (Int64, Int64) async -> Void
    ) async throws {
        throw SSHError.commandFailed("SFTP chunked write not supported in relay mode")
    }

    // MARK: - 事件处理（由外部转发调用）

    /// 处理从 RelayConnection 事件流中转发的工具相关事件。
    /// ChatViewModel 在消费事件时，将 toolDone/toolError/toolProgress 转发到此方法。
    func handleEvent(_ event: RelayEvent) {
        switch event {
        case .toolDone(let id, let exitCode, let output):
            // 流式调用：finish stream（不再 yield output，daemon 已通过 toolProgress 逐行发送）
            if let streamCont = pendingStreams.removeValue(forKey: id) {
                streamCont.finish()
            }
            // 非流式调用：恢复等待续体
            if let continuation = pendingCalls.removeValue(forKey: id) {
                continuation.resume(returning: ToolExecResult(exitCode: exitCode, output: output))
            }

        case .toolError(let id, let error):
            // 如果有流式续体，结束并报错
            if let streamCont = pendingStreams.removeValue(forKey: id) {
                streamCont.finish(throwing: SSHError.commandFailed(error))
            }

            // 恢复等待续体
            if let continuation = pendingCalls.removeValue(forKey: id) {
                continuation.resume(throwing: SSHError.commandFailed(error))
            }

        case .toolProgress(let id, _, let data):
            // 流式输出：yield 到对应的 stream continuation
            if let streamCont = pendingStreams[id] {
                streamCont.yield(data)
            }

        case .disconnected:
            // 连接断开时，所有等待中的调用都失败
            failAllPendingCalls(error: SSHError.notConnected)

        default:
            break
        }
    }

    // MARK: - Private

    /// 先注册 continuation 再执行发送，避免快速响应到达时 continuation 尚未注册。
    private func sendAndWait(
        callID: String,
        timeout: TimeInterval,
        send: @escaping @Sendable () async throws -> Void
    ) async throws -> ToolExecResult {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ToolExecResult, Error>) in
            pendingCalls[callID] = continuation

            Task {
                do {
                    try await send()
                } catch {
                    if let cont = self.pendingCalls.removeValue(forKey: callID) {
                        cont.resume(throwing: error)
                    }
                    return
                }

                // 超时保护
                try? await Task.sleep(for: .seconds(timeout))
                if let cont = self.pendingCalls.removeValue(forKey: callID) {
                    cont.resume(throwing: SSHError.timeout)
                    if let streamCont = self.pendingStreams.removeValue(forKey: callID) {
                        streamCont.finish(throwing: SSHError.timeout)
                    }
                }
            }
        }
    }

    /// 清理流式续体。
    private func cleanupStream(callID: String) {
        pendingStreams.removeValue(forKey: callID)
    }

    /// 连接断开时，使所有等待中的调用失败。
    private func failAllPendingCalls(error: Error) {
        for (_, continuation) in pendingCalls {
            continuation.resume(throwing: error)
        }
        pendingCalls.removeAll()

        for (_, streamCont) in pendingStreams {
            streamCont.finish(throwing: error)
        }
        pendingStreams.removeAll()
    }
}
