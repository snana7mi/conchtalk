import Foundation
import Citadel
import Crypto
import NIOCore
import NIOFoundationCompat
import NIOSSH

actor NIOSSHClient: SSHClientProtocol {
    private var client: SSHClient?
    private var _isConnected = false

    nonisolated var isConnected: Bool {
        get async { await _isConnected }
    }

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

    func disconnect() async {
        if let client {
            try? await client.close()
        }
        self.client = nil
        self._isConnected = false
    }

    func execute(command: String) async throws -> String {
        guard _isConnected, let client else {
            throw SSHError.notConnected
        }

        do {
            let output = try await client.executeCommand(command)
            return String(data: Data(buffer: output), encoding: .utf8) ?? ""
        } catch {
            self._isConnected = false
            self.client = nil
            throw SSHError.commandFailed(error.localizedDescription)
        }
    }

    // MARK: - Private Key Parsing

    /// Try parsing the key in all supported formats:
    /// 1. OpenSSH format (Ed25519) — with optional passphrase
    /// 2. PEM PKCS#1 format (RSA) — uses rsa-sha2-256 signing (modern servers)
    /// 3. OpenSSH format (RSA) — fallback to Citadel's ssh-rsa signing
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

enum SSHError: LocalizedError {
    case notConnected
    case connectionFailed(String)
    case authenticationFailed
    case commandFailed(String)
    case timeout

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
