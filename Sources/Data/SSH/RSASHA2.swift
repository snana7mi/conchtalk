import Foundation
import CCryptoBoringSSL
import NIOSSH
import NIOCore
import Citadel

// MARK: - NID Constants (from BoringSSL nid.h)

private let kNID_sha256: CInt = 672
private let kNID_sha512: CInt = 674

// MARK: - Config Protocol (Phantom Type)

nonisolated protocol RSASHA2Config: Sendable {
    static var algorithmName: String { get }
    static var hashNID: CInt { get }
    static var hashLength: Int { get }
    static func computeHash(_ data: [UInt8]) -> [UInt8]
}

nonisolated enum SHA256Config: RSASHA2Config {
    static let algorithmName = "rsa-sha2-256"
    static let hashNID: CInt = kNID_sha256
    static let hashLength = 32

    static func computeHash(_ data: [UInt8]) -> [UInt8] {
        var hash = [UInt8](repeating: 0, count: hashLength)
        data.withUnsafeBufferPointer { ptr in
            _ = CCryptoBoringSSL_SHA256(ptr.baseAddress, ptr.count, &hash)
        }
        return hash
    }
}

nonisolated enum SHA512Config: RSASHA2Config {
    static let algorithmName = "rsa-sha2-512"
    static let hashNID: CInt = kNID_sha512
    static let hashLength = 64

    static func computeHash(_ data: [UInt8]) -> [UInt8] {
        var hash = [UInt8](repeating: 0, count: hashLength)
        data.withUnsafeBufferPointer { ptr in
            _ = CCryptoBoringSSL_SHA512(ptr.baseAddress, ptr.count, &hash)
        }
        return hash
    }
}

// MARK: - ByteBuffer SSH Helpers (file-private)

extension ByteBuffer {
    /// Write bytes as SSH string (uint32 length + data).
    @discardableResult
    fileprivate mutating func sshWriteBytes(_ bytes: some Collection<UInt8>) -> Int {
        var written = writeInteger(UInt32(bytes.count))
        written += writeBytes(bytes)
        return written
    }

    /// Write an integer as SSH mpint (big-endian, leading zero if high bit set).
    @discardableResult
    fileprivate mutating func sshWriteMPInt(_ bytes: [UInt8]) -> Int {
        if bytes.isEmpty || (bytes.count == 1 && bytes[0] == 0) {
            return writeInteger(UInt32(0))
        }

        // Strip unnecessary leading zeros
        var start = 0
        while start < bytes.count - 1 && bytes[start] == 0 {
            start += 1
        }

        let needsPadding = bytes[start] & 0x80 != 0
        let payloadLen = bytes.count - start + (needsPadding ? 1 : 0)

        var written = writeInteger(UInt32(payloadLen))
        if needsPadding {
            written += writeInteger(UInt8(0))
        }
        written += writeBytes(bytes[start...])
        return written
    }

    /// Read SSH string and return raw bytes.
    fileprivate mutating func sshReadBytes() -> [UInt8]? {
        guard let length = readInteger(as: UInt32.self),
              readableBytes >= length,
              let bytes = readBytes(length: Int(length)) else {
            return nil
        }
        return bytes
    }

    /// Read SSH mpint and return raw bytes (leading zero stripped).
    fileprivate mutating func sshReadMPInt() -> [UInt8]? {
        guard let length = readInteger(as: UInt32.self) else { return nil }
        if length == 0 { return [0] }
        guard readableBytes >= length,
              let bytes = readBytes(length: Int(length)) else {
            return nil
        }
        if bytes.first == 0 && bytes.count > 1 {
            return Array(bytes.dropFirst())
        }
        return bytes
    }
}

// MARK: - Signature

nonisolated struct RSASHA2Signature<Config: RSASHA2Config>: NIOSSHSignatureProtocol, Sendable {
    static var signaturePrefix: String { Config.algorithmName }

    let rawRepresentation: Data

    init(rawBytes: [UInt8]) {
        self.rawRepresentation = Data(rawBytes)
    }

    init(rawRepresentation: Data) {
        self.rawRepresentation = rawRepresentation
    }

    // NIOSSH writes signaturePrefix before calling this method.
    func write(to buffer: inout ByteBuffer) -> Int {
        buffer.sshWriteBytes(rawRepresentation)
    }

    // NIOSSH already consumed the signaturePrefix before calling this method.
    static func read(from buffer: inout ByteBuffer) throws -> Self {
        guard let bytes = buffer.sshReadBytes() else {
            throw RSASHA2Error.invalidSignature
        }
        return Self(rawBytes: bytes)
    }
}

// MARK: - Public Key

nonisolated struct RSASHA2PublicKey<Config: RSASHA2Config>: NIOSSHPublicKeyProtocol, Sendable {
    static var publicKeyPrefix: String { Config.algorithmName }

    let nBytes: [UInt8]  // modulus
    let eBytes: [UInt8]  // public exponent

    var rawRepresentation: Data {
        var buffer = ByteBuffer()
        _ = write(to: &buffer)
        return Data(buffer.readableBytesView)
    }

    func isValidSignature<D: DataProtocol>(_ signature: NIOSSHSignatureProtocol, for data: D) -> Bool {
        guard let sig = signature as? RSASHA2Signature<Config> else { return false }

        guard let rsa = CCryptoBoringSSL_RSA_new() else { return false }
        defer { CCryptoBoringSSL_RSA_free(rsa) }

        let bn_n = nBytes.withUnsafeBufferPointer { CCryptoBoringSSL_BN_bin2bn($0.baseAddress, $0.count, nil) }
        let bn_e = eBytes.withUnsafeBufferPointer { CCryptoBoringSSL_BN_bin2bn($0.baseAddress, $0.count, nil) }
        guard let bn_n, let bn_e else { return false }

        guard CCryptoBoringSSL_RSA_set0_key(rsa, bn_n, bn_e, nil) == 1 else { return false }

        let hash = Config.computeHash(Array(data))
        let sigBytes = Array(sig.rawRepresentation)

        return hash.withUnsafeBufferPointer { hashPtr in
            sigBytes.withUnsafeBufferPointer { sigPtr in
                CCryptoBoringSSL_RSA_verify(
                    Config.hashNID,
                    hashPtr.baseAddress, hash.count,
                    sigPtr.baseAddress, sigBytes.count,
                    rsa
                ) == 1
            }
        }
    }

    // NIOSSH writes publicKeyPrefix before calling this method.
    func write(to buffer: inout ByteBuffer) -> Int {
        var written = 0
        written += buffer.sshWriteMPInt(eBytes)
        written += buffer.sshWriteMPInt(nBytes)
        return written
    }

    // NIOSSH already consumed the publicKeyPrefix before calling this method.
    static func read(from buffer: inout ByteBuffer) throws -> Self {
        guard let eBytes = buffer.sshReadMPInt(),
              let nBytes = buffer.sshReadMPInt() else {
            throw RSASHA2Error.invalidKey
        }
        return Self(nBytes: nBytes, eBytes: eBytes)
    }
}

// MARK: - Private Key

nonisolated struct RSASHA2PrivateKey<Config: RSASHA2Config>: NIOSSHPrivateKeyProtocol, Sendable {
    static var keyPrefix: String { Config.algorithmName }

    let nBytes: [UInt8]  // modulus
    let eBytes: [UInt8]  // public exponent
    let dBytes: [UInt8]  // private exponent

    var publicKey: NIOSSHPublicKeyProtocol {
        RSASHA2PublicKey<Config>(nBytes: nBytes, eBytes: eBytes)
    }

    func signature<D: DataProtocol>(for data: D) throws -> NIOSSHSignatureProtocol {
        let dataArray = Array(data)

        guard let rsa = CCryptoBoringSSL_RSA_new() else {
            throw RSASHA2Error.signingFailed
        }
        defer { CCryptoBoringSSL_RSA_free(rsa) }

        // Create BIGNUMs from raw bytes (RSA_set0_key takes ownership)
        let bn_n = nBytes.withUnsafeBufferPointer { CCryptoBoringSSL_BN_bin2bn($0.baseAddress, $0.count, nil) }
        let bn_e = eBytes.withUnsafeBufferPointer { CCryptoBoringSSL_BN_bin2bn($0.baseAddress, $0.count, nil) }
        let bn_d = dBytes.withUnsafeBufferPointer { CCryptoBoringSSL_BN_bin2bn($0.baseAddress, $0.count, nil) }
        guard let bn_n, let bn_e, let bn_d else {
            throw RSASHA2Error.signingFailed
        }

        guard CCryptoBoringSSL_RSA_set0_key(rsa, bn_n, bn_e, bn_d) == 1 else {
            throw RSASHA2Error.signingFailed
        }

        // Hash the data with SHA-256 or SHA-512
        let hash = Config.computeHash(dataArray)

        // Sign with RSA PKCS#1 v1.5
        let rsaSize = Int(CCryptoBoringSSL_RSA_size(rsa))
        var sigBuffer = [UInt8](repeating: 0, count: rsaSize)
        var sigLen: CUnsignedInt = 0

        let result = hash.withUnsafeBufferPointer { hashPtr in
            CCryptoBoringSSL_RSA_sign(
                Config.hashNID,
                hashPtr.baseAddress, hash.count,
                &sigBuffer, &sigLen,
                rsa
            )
        }

        guard result == 1 else {
            throw RSASHA2Error.signingFailed
        }

        return RSASHA2Signature<Config>(rawBytes: Array(sigBuffer.prefix(Int(sigLen))))
    }
}

// MARK: - Custom Auth Delegate

/// Offers public-key authentication with a custom NIOSSHPrivateKey.
nonisolated final class RSASHA2AuthDelegate: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    private let username: String
    private let privateKey: NIOSSHPrivateKey
    private var offered = false

    init(username: String, privateKey: NIOSSHPrivateKey) {
        self.username = username
        self.privateKey = privateKey
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        guard !offered, availableMethods.contains(.publicKey) else {
            nextChallengePromise.succeed(nil)
            return
        }
        offered = true
        nextChallengePromise.succeed(
            NIOSSHUserAuthenticationOffer(
                username: username,
                serviceName: "",
                offer: .privateKey(.init(privateKey: privateKey))
            )
        )
    }
}

// MARK: - Public API

nonisolated enum RSASHA2 {

    /// Register rsa-sha2-256 and rsa-sha2-512 algorithms with NIOSSH.
    /// Must be called before connecting. Thread-safe (idempotent).
    static func register() {
        _ = Self._registered
    }

    private static let _registered: Void = {
        NIOSSHAlgorithms.register(
            publicKey: RSASHA2PublicKey<SHA256Config>.self,
            signature: RSASHA2Signature<SHA256Config>.self
        )
        NIOSSHAlgorithms.register(
            publicKey: RSASHA2PublicKey<SHA512Config>.self,
            signature: RSASHA2Signature<SHA512Config>.self
        )
    }()

    /// Create an SSHAuthenticationMethod using rsa-sha2-256 signing.
    static func authMethod(username: String, n: [UInt8], e: [UInt8], d: [UInt8]) -> SSHAuthenticationMethod {
        let privateKey = RSASHA2PrivateKey<SHA256Config>(nBytes: n, eBytes: e, dBytes: d)
        let nioKey = NIOSSHPrivateKey(custom: privateKey)
        let delegate = RSASHA2AuthDelegate(username: username, privateKey: nioKey)
        return .custom(delegate)
    }

    /// Extract raw byte array from a BoringSSL BIGNUM pointer.
    static func bignumToBytes(_ bn: UnsafeMutablePointer<BIGNUM>) -> [UInt8] {
        let numBytes = Int(CCryptoBoringSSL_BN_num_bytes(bn))
        guard numBytes > 0 else { return [0] }
        var bytes = [UInt8](repeating: 0, count: numBytes)
        bytes.withUnsafeMutableBufferPointer { ptr in
            _ = CCryptoBoringSSL_BN_bn2bin(bn, ptr.baseAddress)
        }
        return bytes
    }
}

// MARK: - Errors

nonisolated enum RSASHA2Error: LocalizedError {
    case signingFailed
    case invalidKey
    case invalidSignature

    var errorDescription: String? {
        switch self {
        case .signingFailed: return String(localized: "RSA SHA-2 signing failed")
        case .invalidKey: return String(localized: "Invalid RSA key data")
        case .invalidSignature: return String(localized: "Invalid RSA SHA-2 signature")
        }
    }
}
