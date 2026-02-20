/// 文件说明：NIOSSHClient，封装基于 NIOSSH/Citadel 的连接建立、命令执行与密钥认证流程。
import Foundation
import Citadel
import Crypto
import NIOCore
import NIOFoundationCompat
import NIOSSH

/// NIOSSHClient：
/// `SSHClientProtocol` 的具体实现，负责维护单连接状态、
/// 处理密码/私钥认证并执行远端命令流读取。
/// 支持主机密钥 TOFU 验证、连接保活、命令超时与流式输出。
actor NIOSSHClient: SSHClientProtocol {
    private var client: SSHClient?
    private var _isConnected = false
    private var keepAliveTask: Task<Void, Never>?
    private let knownHostsStore: KnownHostsStore

    nonisolated var isConnected: Bool {
        get async { await _isConnected }
    }

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
            throw SSHError.connectionFailed(error.localizedDescription)
        }
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

        return try await withThrowingTaskGroup(of: String.self) { group in
            // 任务 1：实际命令执行
            group.addTask {
                try await Self.executeOnClient(client, command: command)
            }

            // 任务 2：超时守卫
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
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

    /// 在指定 SSHClient 上执行命令（纯函数，不依赖 actor 状态）。
    nonisolated private static func executeOnClient(_ client: SSHClient, command: String) async throws -> String {
        do {
            let stream = try await client.executeCommandStream(command)
            var stdout = ByteBuffer()
            var stderr = ByteBuffer()

            for try await chunk in stream {
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
            Task {
                guard await self._isConnected, let client = await self.client else {
                    continuation.finish(throwing: SSHError.notConnected)
                    return
                }

                do {
                    let stream = try await client.executeCommandStream(command)
                    for try await chunk in stream {
                        let buffer: ByteBuffer
                        switch chunk {
                        case .stdout(let buf):
                            buffer = buf
                        case .stderr(let buf):
                            buffer = buf
                        }
                        if let text = String(data: Data(buffer: buffer), encoding: .utf8), !text.isEmpty {
                            continuation.yield(text)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
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

    // MARK: - Keep-Alive

    /// 启动连接保活定时器（每 30 秒执行一次轻量探测命令）。
    /// - Note: 保活失败时自动标记断连。
    private func startKeepAlive() {
        cancelKeepAlive()
        keepAliveTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch {
                    break
                }
                guard let self else { break }
                do {
                    _ = try await Self.executeOnClient(self.client!, command: "echo __keepalive__")
                } catch {
                    print("[SSH] Keep-alive failed: \(error)")
                    await self.markDisconnected()
                    break
                }
            }
        }
    }

    /// 取消正在运行的保活任务。
    private func cancelKeepAlive() {
        keepAliveTask?.cancel()
        keepAliveTask = nil
    }

    /// 标记连接已断开并清理客户端引用。
    private func markDisconnected() {
        self._isConnected = false
        self.client = nil
        cancelKeepAlive()
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
enum SSHError: LocalizedError {
    case notConnected
    case connectionFailed(String)
    case authenticationFailed
    case commandFailed(String)
    case timeout
    case hostKeyMismatch(host: String, stored: String, received: String)

    /// 适用于 UI 展示的本地化错误文案。
    var errorDescription: String? {
        switch self {
        case .notConnected: return String(localized: "Not connected to server")
        case .connectionFailed(let msg): return String(localized: "Connection failed: \(msg)")
        case .authenticationFailed: return String(localized: "Authentication failed")
        case .commandFailed(let msg): return String(localized: "Command failed: \(msg)")
        case .timeout: return String(localized: "Connection timed out")
        case .hostKeyMismatch(let host, let stored, let received):
            return String(localized: "Host key mismatch for \(host). Expected fingerprint \(stored), but received \(received). This may indicate a man-in-the-middle attack.")
        }
    }
}
