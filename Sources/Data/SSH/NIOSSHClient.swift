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
actor NIOSSHClient: SSHClientProtocol {
    private var client: SSHClient?
    private var _isConnected = false

    nonisolated var isConnected: Bool {
        get async { await _isConnected }
    }

    /// 建立 SSH 连接。
    /// - Parameters:
    ///   - server: 目标服务器配置。
    ///   - password: 密码认证凭据（密码模式使用）。
    ///   - sshKeyData: 私钥数据（私钥模式使用）。
    ///   - keyPassphrase: 私钥口令（加密私钥时使用）。
    /// - Throws: 认证参数不完整、密钥解析失败或网络连接失败时抛出。
    /// - Side Effects:
    ///   - 若已有连接会先执行断开。
    ///   - 成功后写入 `client` 并将 `_isConnected` 置为 `true`。
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

        do {
            let sshClient = try await SSHClient.connect(
                host: server.host,
                port: server.port,
                authenticationMethod: authMethod,
                hostKeyValidator: .acceptAnything(),
                reconnect: .never
            )
            self.client = sshClient
            self._isConnected = true
        } catch {
            self._isConnected = false
            throw SSHError.connectionFailed(error.localizedDescription)
        }
    }

    /// 断开当前连接并清理客户端状态。
    /// - Side Effects: 关闭底层连接、清空 `client`、重置 `_isConnected`。
    func disconnect() async {
        if let client {
            try? await client.close()
        }
        self.client = nil
        self._isConnected = false
    }

    /// 在远端执行命令并返回聚合输出。
    /// - Parameter command: 待执行命令。
    /// - Returns: 标准输出与标准错误按规则合并后的文本。
    /// - Throws:
    ///   - 未连接时抛出 `SSHError.notConnected`。
    ///   - 命令失败或连接异常时抛出 `SSHError.commandFailed`。
    /// - Side Effects: 发生连接级错误时会主动重置本地连接状态。
    func execute(command: String) async throws -> String {
        guard _isConnected, let client else {
            throw SSHError.notConnected
        }

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
            // This shouldn't happen with executeCommandStream, but handle as fallback
            print("[SSH] TTYSTDError for command: \(command)")
            throw SSHError.commandFailed("Command produced error output")
        } catch let error as SSHClient.CommandFailed {
            // Non-zero exit code — command failed but connection is fine
            print("[SSH] Command failed (exit \(error.exitCode)): \(command)")
            throw SSHError.commandFailed("Exit code: \(error.exitCode)")
        } catch {
            // Real connection-level error — disconnect
            print("[SSH] Connection error: \(error)")
            self._isConnected = false
            self.client = nil
            throw SSHError.commandFailed(error.localizedDescription)
        }
    }

    // MARK: - Private Key Parsing

    /// 解析私钥并构建认证方式，按支持格式依次回退尝试：
    /// 1. OpenSSH Ed25519（可选口令）
    /// 2. PEM RSA（通过 `RSASHA2` 走 rsa-sha2-256）
    /// 3. OpenSSH RSA（回退 Citadel 的 ssh-rsa）
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

        // 2. Try PEM PKCS#1 RSA (BEGIN RSA PRIVATE KEY / BEGIN PRIVATE KEY) → rsa-sha2-256
        if PEMKeyParser.isPEMFormat(keyString) {
            let (n, e, d) = try PEMKeyParser.parseRSAKeyBytes(pemString: keyString, passphrase: passphrase)
            return RSASHA2.authMethod(username: username, n: n, e: e, d: d)
        }

        // 3. Try OpenSSH RSA — Citadel's ssh-rsa (SHA-1) as fallback
        if let key = try? Insecure.RSA.PrivateKey(sshRsa: keyString, decryptionKey: passphraseData) {
            return .rsa(username: username, privateKey: key)
        }

        throw SSHError.authenticationFailed
    }
}

/// SSHError：表示 SSH 连接、认证与命令执行过程中的标准错误。
enum SSHError: LocalizedError {
    case notConnected
    case connectionFailed(String)
    case authenticationFailed
    case commandFailed(String)
    case timeout

    /// 适用于 UI 展示的本地化错误文案。
    var errorDescription: String? {
        switch self {
        case .notConnected: return String(localized: "Not connected to server")
        case .connectionFailed(let msg): return String(localized: "Connection failed: \(msg)")
        case .authenticationFailed: return String(localized: "Authentication failed")
        case .commandFailed(let msg): return String(localized: "Command failed: \(msg)")
        case .timeout: return String(localized: "Connection timed out")
        }
    }
}
