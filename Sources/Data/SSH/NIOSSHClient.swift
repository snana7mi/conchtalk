/// 文件说明：NIOSSHClient，封装基于 NIOSSH/Citadel 的连接建立、命令执行与密钥认证流程。
import Foundation
import Citadel
import Crypto
import NIOCore
import NIOFoundationCompat
import NIOSSH
import os

/// NIOSSHClient：
/// `SSHClientProtocol` 的具体实现，负责维护单连接状态、
/// 处理密码/私钥认证并执行远端命令流读取。
/// 支持主机密钥 TOFU 验证、连接保活、命令超时与流式输出。
actor NIOSSHClient: SSHClientProtocol {
    private var client: SSHClient?
    private var _isConnected = false
    private var keepAliveTask: Task<Void, Never>?
    private let knownHostsStore: KnownHostsStore
    private var _capabilities: ServerCapabilities = .unknown

    /// 断线回调：keepalive 检测到连接丢失时触发，通知上层（SSHSessionManager）立即更新 UI 状态。
    private var onDisconnected: (@Sendable (UUID) -> Void)?

    /// 当前关联的服务器 ID（由 SSHSessionManager 在注册时设置）。
    private(set) var serverID: UUID?

    /// 设置关联的服务器 ID。
    func setServerID(_ id: UUID) {
        serverID = id
    }

    /// 设置断线回调。
    func setOnDisconnected(_ handler: (@Sendable (UUID) -> Void)?) {
        onDisconnected = handler
    }

    nonisolated var isConnected: Bool {
        get async { await _isConnected }
    }

    nonisolated var serverCapabilities: ServerCapabilities {
        get async { await _capabilities }
    }

    /// 设置服务器能力探测结果（由 SSHSessionManager 在连接后调用）。
    func setCapabilities(_ caps: ServerCapabilities) {
        _capabilities = caps
    }

    /// 暴露底层 Citadel SSHClient，供 ShellChannel 打开持久 shell。
    var citadelClient: SSHClient? { client }

    // MARK: - Initialization

    /// 初始化 SSH 客户端。
    /// - Parameter knownHostsStore: 已知主机密钥存储；传 `nil` 使用默认实例。
    init(knownHostsStore: KnownHostsStore? = nil) {
        self.knownHostsStore = knownHostsStore ?? KnownHostsStore()
    }

    // MARK: - Connect

    /// 建立 SSH 连接。
    /// - Parameters:
    ///   - server: 目标服务器配置。
    ///   - password: 密码认证凭据（密码模式使用）。
    ///   - sshKeyData: 私钥数据（私钥模式使用）。
    ///   - keyPassphrase: 私钥口令（加密私钥时使用）。
    /// - Throws: 认证参数不完整、密钥解析失败、主机密钥不匹配或网络连接失败时抛出。
    /// - Side Effects:
    ///   - 若已有连接会先执行断开。
    ///   - 成功后写入 `client` 并将 `_isConnected` 置为 `true`，同时启动保活。
    func connect(to server: Server, password: String?, sshKeyData: Data?, keyPassphrase: String?) async throws {
        if _isConnected {
            await disconnect()
        }

        let authMethod: SSHAuthenticationMethod

        switch server.authMethod {
        case .password:
            guard let password else {
                throw SSHError.authenticationFailed
            }
            authMethod = .passwordBased(username: server.username, password: password)

        case .privateKey:
            guard let keyData = sshKeyData, let keyString = String(data: keyData, encoding: .utf8) else {
                throw SSHError.authenticationFailed
            }
            authMethod = try Self.parsePrivateKey(keyString: keyString, username: server.username, passphrase: keyPassphrase)
        }

        // 构建基于 KnownHostsStore 的主机密钥校验器（TOFU）
        let hostKeyValidator = await knownHostsStore.makeValidator(host: server.host, port: server.port)

        do {
            let sshClient = try await SSHClient.connect(
                host: server.host,
                port: server.port,
                authenticationMethod: authMethod,
                hostKeyValidator: hostKeyValidator,
                reconnect: .never
            )
            self.client = sshClient
            self._isConnected = true
            startKeepAlive()
        } catch let error as SSHError {
            // 直接传播已知 SSH 错误（如 hostKeyMismatch）
            self._isConnected = false
            throw error
        } catch {
            self._isConnected = false
            throw Self.classifyConnectionError(error)
        }
    }

    // MARK: - Error Classification

    /// Classifies raw NIO/SSH errors into user-friendly SSHError cases.
    nonisolated private static func classifyConnectionError(_ error: Error) -> SSHError {
        let description = String(describing: error)

        // ChannelError.eof — remote closed connection during handshake/auth
        if error is ChannelError || description.contains("ChannelError") {
            if description.contains("eof") || description.contains("error 0") {
                return .connectionFailed(
                    String(localized: "Server closed the connection during authentication. Please check: 1) your credentials are correct; 2) the authentication method (password/key) matches the server configuration; 3) your IP is not blocked by the server.")
                )
            }
            if description.lowercased().contains("timeout") {
                return .timeout
            }
            return .connectionFailed(
                String(localized: "Network channel error: \(description)")
            )
        }

        // Connection refused
        if description.contains("Connection refused") {
            return .connectionFailed(
                String(localized: "Connection refused. Please verify the server address and port, and ensure the SSH service is running.")
            )
        }

        // DNS resolution failure
        if description.contains("nodename nor servname") || description.contains("getaddrinfo") || description.contains("No address associated") {
            return .connectionFailed(
                String(localized: "Unable to resolve hostname. Please check the server address.")
            )
        }

        // Network unreachable
        if description.contains("Network is unreachable") || description.contains("No route to host") {
            return .connectionFailed(
                String(localized: "Network unreachable. Please check your internet connection.")
            )
        }

        // Timeout
        if description.contains("timed out") || description.contains("Operation timed out") {
            return .timeout
        }

        // Fallback
        return .connectionFailed(error.localizedDescription)
    }

    // MARK: - Disconnect

    /// 断开当前连接并清理客户端状态。
    /// - Side Effects: 取消保活、关闭底层连接、清空 `client`、重置 `_isConnected`。
    func disconnect() async {
        cancelKeepAlive()
        if let client {
            try? await client.close()
        }
        self.client = nil
        self._isConnected = false
    }

    // MARK: - Execute (with timeout)

    /// 在远端执行命令并返回聚合输出。
    /// - Parameters:
    ///   - command: 待执行命令。
    ///   - timeout: 超时时间（秒），默认 30 秒。
    /// - Returns: 标准输出与标准错误按规则合并后的文本。
    /// - Throws:
    ///   - 未连接时抛出 `SSHError.notConnected`。
    ///   - 超时时抛出 `SSHError.timeout`。
    ///   - 命令失败或连接异常时抛出 `SSHError.commandFailed`。
    /// - Side Effects: 发生连接级错误时会主动重置本地连接状态。
    func execute(command: String, timeout: TimeInterval = 30) async throws -> String {
        guard _isConnected, let client else {
            throw SSHError.notConnected
        }

        // 同步完成标志：执行子任务退出时置位（OSAllocatedUnfairLock 满足 Sendable，无 await 开销）
        let finished = OSAllocatedUnfairLock(initialState: false)

        return try await withThrowingTaskGroup(of: String.self) { group in
            // 任务 1：实际命令执行
            group.addTask {
                defer { finished.withLock { $0 = true } }
                return try await Self.executeOnClient(client, command: command)
            }

            // 任务 2：超时守卫 + 宽限 watchdog
            group.addTask { [weak self] in
                try await Task.sleep(for: .seconds(timeout))
                // 宽限 watchdog：取消信号发出后，执行子任务若仍未在宽限期内退出，
                // 说明其挂在不可取消的 NIO future 上（半开连接）——强制关闭整条连接，
                // fail 所有挂起 future，解除 task group 的隐式等待。
                Task.detached {
                    try? await Task.sleep(for: .seconds(Self.hangGraceSeconds))
                    if !finished.withLock({ $0 }) {
                        await self?.forceCloseAfterHang()
                    }
                }
                throw SSHError.timeout
            }

            // 取首个完成结果，取消另一个
            guard let result = try await group.next() else {
                throw SSHError.commandFailed("No result")
            }
            group.cancelAll()
            return result
        }
    }

    /// 超时宽限期（秒）：超时取消后执行子任务仍未退出则判定连接挂死。
    private static let hangGraceSeconds: TimeInterval = 5

    /// 挂死强制断连：关闭底层连接以 fail 所有挂起的 NIO future，并统一走断线回调通知上层。
    /// watchdog 持 weak self：actor 已释放则无连接可关，静默退出。
    private func forceCloseAfterHang() async {
        guard let client else { return }
        print("[SSH] Execute hang detected after timeout grace period, force closing connection")
        try? await client.close()
        markDisconnected()
    }

    /// 在指定 SSHClient 上执行命令（纯函数，不依赖 actor 状态）。
    nonisolated private static func executeOnClient(_ client: SSHClient, command: String) async throws -> String {
        do {
            let stream = try await client.executeCommandStream(command)
            var stdout = ByteBuffer()
            var stderr = ByteBuffer()

            for try await chunk in stream {
                try Task.checkCancellation()  // 对齐 executeStreaming：超时取消后立即退出，不再消费到流自然结束
                switch chunk {
                case .stdout(var buffer):
                    stdout.writeBuffer(&buffer)
                case .stderr(var buffer):
                    stderr.writeBuffer(&buffer)
                }
            }

            let stdoutStr = String(data: Data(buffer: stdout), encoding: .utf8) ?? ""
            let stderrStr = String(data: Data(buffer: stderr), encoding: .utf8) ?? ""

            if !stderrStr.isEmpty {
                print("[SSH stderr] \(command): \(stderrStr)")
            }

            // Merge stdout and stderr — stderr is informational, not a fatal error
            if stdoutStr.isEmpty && !stderrStr.isEmpty {
                return stderrStr
            } else if !stderrStr.isEmpty {
                return stdoutStr + "\n[stderr]\n" + stderrStr
            }
            return stdoutStr
        } catch is TTYSTDError {
            // TTYSTDError means stderr had content — not a connection failure
            print("[SSH] TTYSTDError for command: \(command)")
            throw SSHError.commandFailed("Command produced error output")
        } catch let error as SSHClient.CommandFailed {
            // Non-zero exit code — command failed but connection is fine
            print("[SSH] Command failed (exit \(error.exitCode)): \(command)")
            throw SSHError.commandFailed("Exit code: \(error.exitCode)")
        }
    }

    // MARK: - Streaming Execute

    /// 以流式方式在远端执行命令，逐块返回输出。
    /// - Parameter command: 待执行命令。
    /// - Returns: 异步抛出流，每个元素为一段输出文本（stdout 或 stderr）。
    /// - Note: 如果未连接会通过流抛出 `SSHError.notConnected`。
    nonisolated func executeStreaming(command: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                guard await self._isConnected, let client = await self.client else {
                    continuation.finish(throwing: SSHError.notConnected)
                    return
                }

                do {
                    let stream = try await client.executeCommandStream(command)
                    // 跨 chunk 累积字节：Citadel 的 chunk 边界是任意字节切分，一个多字节
                    // UTF-8 字符（中/日文 3-4 字节）可能被切在两块之间。按字节累积、只解码到
                    // 最后一个完整 UTF-8 边界，不完整的尾字节留到下一块，避免乱码/丢字。
                    var pending = [UInt8]()
                    for try await chunk in stream {
                        try Task.checkCancellation()
                        let buffer: ByteBuffer
                        switch chunk {
                        case .stdout(let buf):
                            buffer = buf
                        case .stderr(let buf):
                            buffer = buf
                        }
                        pending.append(contentsOf: buffer.readableBytesView)
                        let text = Self.drainDecodableUTF8(&pending)
                        if !text.isEmpty {
                            continuation.yield(text)
                        }
                    }
                    // flush 残留字节（即便末尾不完整也输出，避免静默丢弃）
                    if !pending.isEmpty {
                        let text = String(decoding: pending, as: UTF8.self)
                        if !text.isEmpty { continuation.yield(text) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// 从累积字节缓冲解码出尽可能长的完整 UTF-8 文本，把末尾不完整的多字节序列留在
    /// buffer 里待下一块拼接。从末尾回扫最多 4 字节定位最后一个 lead byte，若其后字节
    /// 不足以构成完整序列则在该处截断、保留尾巴。
    nonisolated private static func drainDecodableUTF8(_ buffer: inout [UInt8]) -> String {
        guard !buffer.isEmpty else { return "" }
        var cut = buffer.count
        var i = buffer.count - 1
        var scanned = 0
        while i >= 0 && scanned < 4 {
            let b = buffer[i]
            if b & 0xC0 != 0x80 {  // 非 continuation byte（10xxxxxx）即 lead byte
                let expected: Int
                if b & 0x80 == 0 { expected = 1 }
                else if b & 0xE0 == 0xC0 { expected = 2 }
                else if b & 0xF0 == 0xE0 { expected = 3 }
                else if b & 0xF8 == 0xF0 { expected = 4 }
                else { expected = 1 }  // 非法 lead，当 1 字节处理
                cut = (buffer.count - i < expected) ? i : buffer.count
                break
            }
            i -= 1
            scanned += 1
        }
        let head = Array(buffer[0..<cut])
        buffer = Array(buffer[cut...])
        return String(decoding: head, as: UTF8.self)
    }

    // MARK: - SFTP

    /// 通过 SFTP 读取远端文件内容。
    func sftpReadFile(path: String) async throws -> Data {
        guard _isConnected, let client else {
            throw SSHError.notConnected
        }

        return try await client.withSFTP { sftp in
            let data = try await sftp.withFile(filePath: path, flags: .read) { file in
                try await file.readAll()
            }
            return Data(buffer: data)
        }
    }

    /// 通过 SFTP 将数据写入远端文件。
    func sftpWriteFile(path: String, data: Data) async throws {
        guard _isConnected, let client else {
            throw SSHError.notConnected
        }

        try await client.withSFTP { sftp in
            try await sftp.withFile(
                filePath: path,
                flags: [.write, .create, .truncate]
            ) { file in
                try await file.write(ByteBuffer(data: data))
            }
        }
    }

    /// 通过 SFTP 获取远端文件大小（字节）。
    func sftpFileSize(path: String) async throws -> UInt64 {
        guard _isConnected, let client else {
            throw SSHError.notConnected
        }

        return try await client.withSFTP { sftp in
            let attributes = try await sftp.getAttributes(at: path)
            guard let size = attributes.size else {
                throw SSHError.commandFailed("Unable to get file size")
            }
            return size
        }
    }

    /// 分块 SFTP 写入，每写完一块调用 onProgress 回调。
    func sftpWriteFileChunked(
        path: String,
        data: Data,
        chunkSize: Int = 256 * 1024,
        onProgress: @escaping @Sendable (Int64, Int64) async -> Void
    ) async throws {
        guard _isConnected, let client else {
            throw SSHError.notConnected
        }

        let totalSize = Int64(data.count)

        try await client.withSFTP { sftp in
            try await sftp.withFile(
                filePath: path,
                flags: [.write, .create, .truncate]
            ) { file in
                var offset = 0
                while offset < data.count {
                    let end = min(offset + chunkSize, data.count)
                    let chunk = data[offset..<end]
                    try await file.write(ByteBuffer(data: Data(chunk)))
                    offset = end
                    await onProgress(Int64(offset), totalSize)
                }
            }
        }
    }

    // MARK: - Keep-Alive

    /// 启动连接保活定时器（每 30 秒执行一次轻量探测命令）。
    /// - Note: 保活失败时自动标记断连。
    private func startKeepAlive() {
        cancelKeepAlive()
        keepAliveTask = Task { [weak self] in
            // 容忍瞬时网络抖动：连续多次失败才判定断线，避免移动网络下一次丢包/慢响应
            // 就误杀健康连接、触发整轮重连（重建 client + 重跑探测）。
            let maxConsecutiveFailures = 3
            var consecutiveFailures = 0
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch {
                    break
                }
                guard let self else { break }
                guard await self.client != nil else { break }
                do {
                    // 走带超时的 execute（10s），防止探测命令本身挂死拖住保活循环。
                    _ = try await self.execute(command: "echo __keepalive__", timeout: 10)
                    consecutiveFailures = 0
                } catch {
                    consecutiveFailures += 1
                    print("[SSH] Keep-alive failed (\(consecutiveFailures)/\(maxConsecutiveFailures)): \(error)")
                    if consecutiveFailures >= maxConsecutiveFailures {
                        await self.markDisconnected()
                        break
                    }
                }
            }
        }
    }

    /// 取消正在运行的保活任务。
    private func cancelKeepAlive() {
        keepAliveTask?.cancel()
        keepAliveTask = nil
    }

    /// 标记连接已断开并清理客户端引用，同时通知上层更新 UI 状态。
    private func markDisconnected() {
        self._isConnected = false
        self.client = nil
        cancelKeepAlive()
        if let serverID {
            onDisconnected?(serverID)
        }
    }

    // MARK: - Private Key Parsing

    /// 解析私钥并构建认证方式，按支持格式依次回退尝试：
    /// 1. OpenSSH Ed25519（可选口令）
    /// 2. ECDSA P-256（PEM 格式，使用 CryptoKit）
    /// 3. PEM RSA（通过 `RSASHA2` 走 rsa-sha2-256）
    /// 4. OpenSSH RSA（回退 Citadel 的 ssh-rsa）
    /// - Parameters:
    ///   - keyString: 私钥文本。
    ///   - username: 登录用户名。
    ///   - passphrase: 私钥口令（可选）。
    /// - Returns: 可用于 Citadel 建连的认证方式对象。
    /// - Throws: 所有格式解析失败时抛出 `SSHError.authenticationFailed`。
    nonisolated private static func parsePrivateKey(keyString: String, username: String, passphrase: String?) throws -> SSHAuthenticationMethod {
        RSASHA2.register()
        let passphraseData = passphrase?.data(using: .utf8)

        // 1. Try OpenSSH Ed25519
        if let key = try? Curve25519.Signing.PrivateKey(sshEd25519: keyString, decryptionKey: passphraseData) {
            return .ed25519(username: username, privateKey: key)
        }

        // 2. Try ECDSA P-256 (PEM format)
        if let key = try? P256.Signing.PrivateKey(pemRepresentation: keyString) {
            return .p256(username: username, privateKey: key)
        }

        // 3. Try PEM PKCS#1 RSA (BEGIN RSA PRIVATE KEY / BEGIN PRIVATE KEY) → rsa-sha2-256
        if PEMKeyParser.isPEMFormat(keyString) {
            let (n, e, d) = try PEMKeyParser.parseRSAKeyBytes(pemString: keyString, passphrase: passphrase)
            return RSASHA2.authMethod(username: username, n: n, e: e, d: d)
        }

        // 4. Try OpenSSH RSA — Citadel's ssh-rsa (SHA-1) as fallback
        if let key = try? Insecure.RSA.PrivateKey(sshRsa: keyString, decryptionKey: passphraseData) {
            return .rsa(username: username, privateKey: key)
        }

        throw SSHError.authenticationFailed
    }
}

// MARK: - SSHError

/// SSHError：表示 SSH 连接、认证与命令执行过程中的标准错误。
enum SSHError: LocalizedError, Equatable {
    case notConnected
    case connectionFailed(String)
    case authenticationFailed
    case commandFailed(String)
    case timeout
    case hostKeyMismatch(host: String, stored: String, received: String)
    case connectionLimitReached

    /// 适用于 UI 展示的本地化错误文案。
    var errorDescription: String? {
        switch self {
        case .notConnected: return String(localized: "Not connected to server")
        case .connectionFailed(let msg): return String(localized: "Connection failed: \(msg)")
        case .authenticationFailed: return String(localized: "Authentication failed. Please check your username and password/key.")
        case .commandFailed(let msg): return String(localized: "Command failed: \(msg)")
        case .timeout: return String(localized: "Connection timed out. Please check your network and server address.")
        case .hostKeyMismatch(let host, let stored, let received):
            return String(localized: "Host key mismatch for \(host). Expected fingerprint \(stored), but received \(received). This may indicate a man-in-the-middle attack.")
        case .connectionLimitReached:
            return String(localized: "Free tier allows only one server connection at a time.", bundle: LanguageSettings.currentBundle)
        }
    }
}

#if DEBUG
extension NIOSSHClient {
    /// 测试注入：手动设置连接状态，避免单元测试依赖真实网络连接。
    func setConnectionStateForTesting(isConnected: Bool) {
        _isConnected = isConnected
    }
}
#endif
