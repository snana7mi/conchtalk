/// 文件说明：RSASHA2，提供基于 rsa-sha2-256/512 的 SSH 公钥认证与签名支持。
import Foundation
import CCryptoBoringSSL
import NIOSSH
import NIOCore
import Citadel

// MARK: - NID Constants (from BoringSSL nid.h)

private nonisolated let kNID_sha256: CInt = 672
private nonisolated let kNID_sha512: CInt = 674

// MARK: - Config Protocol (Phantom Type)

/// RSASHA2Config：
/// 通过泛型配置抽象算法差异（算法名、摘要 NID、摘要长度与哈希实现）。
nonisolated protocol RSASHA2Config: Sendable {
    static var algorithmName: String { get }
    static var hashNID: CInt { get }
    static var hashLength: Int { get }
    /// 计算待签名数据的哈希摘要。
    /// - Parameter data: 原始数据字节。
    /// - Returns: 摘要字节数组。
    static func computeHash(_ data: [UInt8]) -> [UInt8]
}

/// SHA256Config：定义 RSA-SHA2-256 签名所需的算法参数。
nonisolated enum SHA256Config: RSASHA2Config {
    static let algorithmName = "rsa-sha2-256"
    static let hashNID: CInt = kNID_sha256
    static let hashLength = 32

    /// computeHash：计算输入数据的哈希摘要。
    static func computeHash(_ data: [UInt8]) -> [UInt8] {
        var hash = [UInt8](repeating: 0, count: hashLength)
        data.withUnsafeBufferPointer { ptr in
            _ = CCryptoBoringSSL_SHA256(ptr.baseAddress, ptr.count, &hash)
        }
        return hash
    }
}

/// SHA512Config：定义 RSA-SHA2-512 签名所需的算法参数。
nonisolated enum SHA512Config: RSASHA2Config {
    static let algorithmName = "rsa-sha2-512"
    static let hashNID: CInt = kNID_sha512
    static let hashLength = 64

    /// computeHash：计算输入数据的哈希摘要。
    static func computeHash(_ data: [UInt8]) -> [UInt8] {
        var hash = [UInt8](repeating: 0, count: hashLength)
        data.withUnsafeBufferPointer { ptr in
            _ = CCryptoBoringSSL_SHA512(ptr.baseAddress, ptr.count, &hash)
        }
        return hash
    }
}

// MARK: - ByteBuffer SSH Helpers (file-private)

/// ByteBuffer 扩展：提供 SSH 协议二进制编码/解码辅助方法。
extension ByteBuffer {
    /// 以 SSH `string` 格式写入字节（`uint32 length + payload`）。
    /// - Parameter bytes: 待写入字节集合。
    /// - Returns: 写入字节数。
    @discardableResult
    fileprivate nonisolated mutating func sshWriteBytes(_ bytes: some Collection<UInt8>) -> Int {
        var written = writeInteger(UInt32(bytes.count))
        written += writeBytes(bytes)
        return written
    }

    /// 以 SSH `mpint` 格式写入大整数（必要时补前导零避免符号位误判）。
    /// - Parameter bytes: 大整数大端字节。
    /// - Returns: 写入字节数。
    @discardableResult
    fileprivate nonisolated mutating func sshWriteMPInt(_ bytes: [UInt8]) -> Int {
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

    /// 按 SSH `string` 格式读取字节数据。
    /// - Returns: 读取成功返回字节数组，否则返回 `nil`。
    fileprivate nonisolated mutating func sshReadBytes() -> [UInt8]? {
        guard let length = readInteger(as: UInt32.self),
              readableBytes >= length,
              let bytes = readBytes(length: Int(length)) else {
            return nil
        }
        return bytes
    }

    /// 按 SSH `mpint` 格式读取大整数并去除符号填充零。
    /// - Returns: 读取成功返回字节数组，否则返回 `nil`。
    fileprivate nonisolated mutating func sshReadMPInt() -> [UInt8]? {
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

/// RSASHA2Signature：RSA-SHA2 签名载荷封装，适配 `NIOSSHSignatureProtocol`。
nonisolated struct RSASHA2Signature<Config: RSASHA2Config>: NIOSSHSignatureProtocol, Sendable {
    static var signaturePrefix: String { Config.algorithmName }

    let rawRepresentation: Data

    /// 通过原始签名字节初始化签名对象。
    /// - Parameter rawBytes: 签名字节。
    init(rawBytes: [UInt8]) {
        self.rawRepresentation = Data(rawBytes)
    }

    /// 通过 `Data` 形式初始化签名对象。
    /// - Parameter rawRepresentation: 签名数据。
    init(rawRepresentation: Data) {
        self.rawRepresentation = rawRepresentation
    }

    // NIOSSH writes signaturePrefix before calling this method.
    /// 将签名写入 SSH 缓冲区（前缀由 NIOSSH 外层处理）。
    func write(to buffer: inout ByteBuffer) -> Int {
        buffer.sshWriteBytes(rawRepresentation)
    }

    // NIOSSH already consumed the signaturePrefix before calling this method.
    /// 从 SSH 缓冲区读取签名载荷并构建签名对象。
    /// - Throws: 载荷结构不合法时抛出 `RSASHA2Error.invalidSignature`。
    static func read(from buffer: inout ByteBuffer) throws -> Self {
        guard let bytes = buffer.sshReadBytes() else {
            throw RSASHA2Error.invalidSignature
        }
        return Self(rawBytes: bytes)
    }
}

// MARK: - Public Key

/// RSASHA2PublicKey：RSA 公钥封装，适配 `NIOSSHPublicKeyProtocol` 验签流程。
nonisolated struct RSASHA2PublicKey<Config: RSASHA2Config>: NIOSSHPublicKeyProtocol, Sendable {
    static var publicKeyPrefix: String { Config.algorithmName }

    let nBytes: [UInt8]  // modulus
    let eBytes: [UInt8]  // public exponent

    var rawRepresentation: Data {
        var buffer = ByteBuffer()
        _ = write(to: &buffer)
        return Data(buffer.readableBytesView)
    }

    /// 使用当前公钥校验签名有效性。
    /// - Parameters:
    ///   - signature: 待校验签名。
    ///   - data: 原始数据。
    /// - Returns: `true` 表示签名有效。
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
    /// 将公钥参数写入 SSH 缓冲区（前缀由 NIOSSH 外层处理）。
    func write(to buffer: inout ByteBuffer) -> Int {
        var written = 0
        written += buffer.sshWriteMPInt(eBytes)
        written += buffer.sshWriteMPInt(nBytes)
        return written
    }

    // NIOSSH already consumed the publicKeyPrefix before calling this method.
    /// 从 SSH 缓冲区读取公钥参数并构建公钥对象。
    /// - Throws: 公钥结构不合法时抛出 `RSASHA2Error.invalidKey`。
    static func read(from buffer: inout ByteBuffer) throws -> Self {
        guard let eBytes = buffer.sshReadMPInt(),
              let nBytes = buffer.sshReadMPInt() else {
            throw RSASHA2Error.invalidKey
        }
        return Self(nBytes: nBytes, eBytes: eBytes)
    }
}

// MARK: - Private Key

/// RSASHA2PrivateKey：RSA 私钥封装，负责生成符合 SSH 协议的签名。
nonisolated struct RSASHA2PrivateKey<Config: RSASHA2Config>: NIOSSHPrivateKeyProtocol, Sendable {
    static var keyPrefix: String { Config.algorithmName }

    let nBytes: [UInt8]  // modulus
    let eBytes: [UInt8]  // public exponent
    let dBytes: [UInt8]  // private exponent

    var publicKey: NIOSSHPublicKeyProtocol {
        RSASHA2PublicKey<Config>(nBytes: nBytes, eBytes: eBytes)
    }

    /// 对输入数据签名并返回 SSH 签名对象。
    /// - Parameter data: 待签名数据。
    /// - Returns: `NIOSSHSignatureProtocol` 签名实例。
    /// - Throws: BIGNUM 构建、RSA 参数设置或签名失败时抛出。
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

/// RSASHA2AuthDelegate：
/// 为 NIOSSH 提供基于自定义私钥的公钥认证协商委托。
nonisolated final class RSASHA2AuthDelegate: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    private let username: String
    private let privateKey: NIOSSHPrivateKey
    private var offered = false

    /// 初始化认证委托。
    /// - Parameters:
    ///   - username: 登录用户名。
    ///   - privateKey: NIOSSH 私钥封装。
    init(username: String, privateKey: NIOSSHPrivateKey) {
        self.username = username
        self.privateKey = privateKey
    }

    /// 根据服务端声明能力决定是否提交公钥认证请求。
    /// - Note: 只会提交一次公钥 offer，后续调用返回 `nil`。
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

/// RSASHA2：对外暴露 RSA-SHA2 算法注册与认证方法构建入口。
nonisolated enum RSASHA2 {

    /// 注册 `rsa-sha2-256` 与 `rsa-sha2-512` 算法到 NIOSSH。
    /// - Note: 线程安全且幂等，建连前调用一次即可。
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

    /// 使用给定 RSA 参数构建 `rsa-sha2-256` 自定义认证方法。
    /// - Parameters:
    ///   - username: 登录用户名。
    ///   - n: 模数字节。
    ///   - e: 公钥指数。
    ///   - d: 私钥指数。
    /// - Returns: 可直接用于 Citadel 连接的认证方法。
    static func authMethod(username: String, n: [UInt8], e: [UInt8], d: [UInt8]) -> SSHAuthenticationMethod {
        let privateKey = RSASHA2PrivateKey<SHA256Config>(nBytes: n, eBytes: e, dBytes: d)
        let nioKey = NIOSSHPrivateKey(custom: privateKey)
        let delegate = RSASHA2AuthDelegate(username: username, privateKey: nioKey)
        return .custom(delegate)
    }

    /// 将 BoringSSL `BIGNUM` 转换为大端字节数组。
    /// - Parameter bn: BIGNUM 指针。
    /// - Returns: 对应字节数组；空值回退为 `[0]`。
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

/// RSASHA2Error：表示 RSA-SHA2 编码、签名与验签过程中的错误。
nonisolated enum RSASHA2Error: LocalizedError {
    case signingFailed
    case invalidKey
    case invalidSignature

    /// 面向 UI 展示的本地化错误文案。
    var errorDescription: String? {
        switch self {
        case .signingFailed: return String(localized: "RSA SHA-2 signing failed")
        case .invalidKey: return String(localized: "Invalid RSA key data")
        case .invalidSignature: return String(localized: "Invalid RSA SHA-2 signature")
        }
    }
}
