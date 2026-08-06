/// 文件说明：SSHKeyGenerationService，负责生成 Ed25519、RSA-4096 和 ECDSA P-256 SSH 密钥对。
import Foundation
import CryptoKit
import Security

/// GeneratedKeyPair：生成的 SSH 密钥对，包含私钥数据、OpenSSH 公钥和指纹。
struct GeneratedKeyPair: Sendable {
    let privateKeyData: Data       // 用于 Keychain 存储的私钥数据
    let publicKeyOpenSSH: String   // "ssh-ed25519 AAAA..." 格式公钥
    let fingerprint: String        // "SHA256:..." 格式指纹
    let keyType: SSHKey.KeyType
}

/// SSHKeyGenerationService：
/// 提供三种 SSH 密钥算法的生成功能，输出标准格式的私钥与公钥数据。
nonisolated enum SSHKeyGenerationService {

    // MARK: - Ed25519 密钥生成

    /// 生成 Ed25519 SSH 密钥对。
    /// 使用 CryptoKit 生成密钥，私钥序列化为 OpenSSH 私钥格式。
    /// - Returns: 包含私钥、公钥和指纹的 `GeneratedKeyPair`。
    static func generateEd25519() -> GeneratedKeyPair {
        let privateKey = Curve25519.Signing.PrivateKey()
        let publicKeyRaw = Data(privateKey.publicKey.rawRepresentation)
        let privateKeyRaw = Data(privateKey.rawRepresentation)

        // 构建 OpenSSH 格式私钥
        let privateKeyPEM = buildOpenSSHEd25519PrivateKey(
            publicKey: publicKeyRaw,
            privateKey: privateKeyRaw
        )

        let publicKeyOpenSSH = SSHPublicKeyEncoder.encodeEd25519(rawPublicKey: publicKeyRaw)

        // 构建公钥 blob 用于指纹计算
        var blob = Data()
        blob.append(sshString("ssh-ed25519"))
        blob.append(sshBytes(publicKeyRaw))

        let fp = SSHPublicKeyEncoder.fingerprint(fromPublicKeyBlob: blob)

        return GeneratedKeyPair(
            privateKeyData: privateKeyPEM,
            publicKeyOpenSSH: publicKeyOpenSSH,
            fingerprint: fp,
            keyType: .ed25519
        )
    }

    // MARK: - RSA-4096 密钥生成

    /// 生成 RSA-4096 SSH 密钥对。
    /// 使用 Security 框架生成密钥，导出为 PKCS#1 PEM 格式。
    /// - Returns: 包含私钥、公钥和指纹的 `GeneratedKeyPair`。
    /// - Throws: Security 框架密钥生成或导出失败时抛出错误。
    static func generateRSA4096() throws -> GeneratedKeyPair {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 4096
        ]

        var error: Unmanaged<CFError>?
        guard let privateSecKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw SSHKeyGenerationError.rsaKeyGenerationFailed(
                error?.takeRetainedValue().localizedDescription ?? "Unknown error"
            )
        }

        // 导出私钥 DER 数据
        guard let privateKeyDER = SecKeyCopyExternalRepresentation(privateSecKey, &error) as Data? else {
            throw SSHKeyGenerationError.rsaKeyExportFailed(
                error?.takeRetainedValue().localizedDescription ?? "Unknown error"
            )
        }

        // 包装为 PKCS#1 PEM 格式
        let privateKeyPEM = wrapPEM(der: privateKeyDER, label: "RSA PRIVATE KEY")

        // 从 DER 中提取 n 和 e 用于公钥编码
        let (n, e) = try extractRSAPublicComponents(from: privateKeyDER)

        let publicKeyOpenSSH = SSHPublicKeyEncoder.encodeRSA(e: e, n: n)

        // 构建公钥 blob 用于指纹计算
        var blob = Data()
        blob.append(sshString("ssh-rsa"))
        blob.append(sshMPInt(e))
        blob.append(sshMPInt(n))

        let fp = SSHPublicKeyEncoder.fingerprint(fromPublicKeyBlob: blob)

        return GeneratedKeyPair(
            privateKeyData: Data(privateKeyPEM.utf8),
            publicKeyOpenSSH: publicKeyOpenSSH,
            fingerprint: fp,
            keyType: .rsa4096
        )
    }

    // MARK: - ECDSA P-256 密钥生成

    /// 生成 ECDSA P-256 SSH 密钥对。
    /// 使用 CryptoKit 生成密钥，导出为 PEM 格式。
    /// - Returns: 包含私钥、公钥和指纹的 `GeneratedKeyPair`。
    static func generateECDSAP256() -> GeneratedKeyPair {
        let privateKey = P256.Signing.PrivateKey()
        let pemString = privateKey.pemRepresentation
        let publicPoint = Data(privateKey.publicKey.x963Representation)

        let publicKeyOpenSSH = SSHPublicKeyEncoder.encodeECDSAP256(publicKeyPoint: publicPoint)

        // 构建公钥 blob 用于指纹计算
        var blob = Data()
        blob.append(sshString("ecdsa-sha2-nistp256"))
        blob.append(sshString("nistp256"))
        blob.append(sshBytes(publicPoint))

        let fp = SSHPublicKeyEncoder.fingerprint(fromPublicKeyBlob: blob)

        return GeneratedKeyPair(
            privateKeyData: Data(pemString.utf8),
            publicKeyOpenSSH: publicKeyOpenSSH,
            fingerprint: fp,
            keyType: .ecdsaP256
        )
    }

    // MARK: - Ed25519 OpenSSH 私钥格式构建

    /// 构建 OpenSSH 格式的 Ed25519 私钥 PEM 数据。
    /// 遵循 `openssh-key-v1` 格式规范，无加密。
    /// - Parameters:
    ///   - publicKey: 32 字节 Ed25519 公钥。
    ///   - privateKey: 32 字节 Ed25519 私钥种子。
    /// - Returns: PEM 编码的私钥数据。
    private static func buildOpenSSHEd25519PrivateKey(publicKey: Data, privateKey: Data) -> Data {
        // AUTH_MAGIC
        let magic = "openssh-key-v1\0"
        var body = Data(magic.utf8)

        // cipher: "none"
        body.append(sshString("none"))
        // kdf: "none"
        body.append(sshString("none"))
        // kdf options: empty string
        body.append(sshBytes(Data()))
        // number of keys: 1
        body.append(uint32BigEndian(1))

        // 公钥 blob: string "ssh-ed25519" + string <32-byte pubkey>
        var publicKeyBlob = Data()
        publicKeyBlob.append(sshString("ssh-ed25519"))
        publicKeyBlob.append(sshBytes(publicKey))
        body.append(sshBytes(publicKeyBlob))

        // 私钥段
        var privateSection = Data()

        // 两个相同的随机 check 字节（用于验证解密是否正确）
        let checkValue = UInt32.random(in: 0...UInt32.max)
        privateSection.append(uint32BigEndian(checkValue))
        privateSection.append(uint32BigEndian(checkValue))

        // string "ssh-ed25519"
        privateSection.append(sshString("ssh-ed25519"))
        // string <32-byte pubkey>
        privateSection.append(sshBytes(publicKey))
        // string <64-byte privkey> (seed 32 bytes + pubkey 32 bytes)
        var fullPrivateKey = Data()
        fullPrivateKey.append(privateKey)
        fullPrivateKey.append(publicKey)
        privateSection.append(sshBytes(fullPrivateKey))
        // string comment (empty)
        privateSection.append(sshString(""))

        // 填充至 8 字节对齐（cipher block size，"none" 时为 8）
        let blockSize = 8
        var padByte: UInt8 = 1
        while privateSection.count % blockSize != 0 {
            privateSection.append(padByte)
            padByte += 1
        }

        body.append(sshBytes(privateSection))

        // PEM 封装
        let base64 = body.base64EncodedString(options: [.lineLength76Characters, .endLineWithLineFeed])
        let pem = "-----BEGIN OPENSSH PRIVATE KEY-----\n\(base64)\n-----END OPENSSH PRIVATE KEY-----\n"
        return Data(pem.utf8)
    }

    // MARK: - RSA DER 解析

    /// 从 PKCS#1 RSA 私钥 DER 中提取公钥分量 (n, e)。
    /// - Parameter der: PKCS#1 DER 格式的 RSA 私钥数据。
    /// - Returns: 模数 n 和公钥指数 e。
    /// - Throws: DER 结构非法时抛出错误。
    private static func extractRSAPublicComponents(from der: Data) throws -> (n: Data, e: Data) {
        let bytes = Array(der)
        var offset = 0

        // SEQUENCE
        guard offset < bytes.count, bytes[offset] == 0x30 else {
            throw SSHKeyGenerationError.invalidDER
        }
        offset += 1
        _ = try readDERLength(bytes, &offset)

        // version INTEGER (应为 0)
        _ = try readDERInteger(bytes, &offset)

        // modulus (n)
        let n = try readDERInteger(bytes, &offset)

        // publicExponent (e)
        let e = try readDERInteger(bytes, &offset)

        return (n: n, e: e)
    }

    // MARK: - PEM 封装

    /// 将 DER 数据封装为 PEM 格式字符串。
    /// - Parameters:
    ///   - der: DER 原始数据。
    ///   - label: PEM 标签（如 "RSA PRIVATE KEY"）。
    /// - Returns: PEM 格式字符串。
    private static func wrapPEM(der: Data, label: String) -> String {
        let base64 = der.base64EncodedString(options: [.lineLength76Characters, .endLineWithLineFeed])
        return "-----BEGIN \(label)-----\n\(base64)\n-----END \(label)-----\n"
    }

    // MARK: - SSH Wire Format 辅助方法

    /// 按 SSH wire format 编码字符串。
    private static func sshString(_ string: String) -> Data {
        sshBytes(Data(string.utf8))
    }

    /// 按 SSH wire format 编码字节。
    private static func sshBytes(_ bytes: Data) -> Data {
        var data = Data()
        var length = UInt32(bytes.count).bigEndian
        data.append(Data(bytes: &length, count: 4))
        data.append(bytes)
        return data
    }

    /// 按 SSH mpint 格式编码大整数（正数高位为 1 时补零）。
    private static func sshMPInt(_ value: Data) -> Data {
        var bytes = value
        if let first = bytes.first, first & 0x80 != 0 {
            bytes.insert(0x00, at: 0)
        }
        return sshBytes(bytes)
    }

    /// 编码 UInt32 为大端序 4 字节。
    private static func uint32BigEndian(_ value: UInt32) -> Data {
        var v = value.bigEndian
        return Data(bytes: &v, count: 4)
    }

    // MARK: - ASN.1 DER 读取辅助

    /// 读取 DER 长度字段。
    private static func readDERLength(_ bytes: [UInt8], _ offset: inout Int) throws -> Int {
        guard offset < bytes.count else { throw SSHKeyGenerationError.invalidDER }

        let first = bytes[offset]
        offset += 1

        if first & 0x80 == 0 {
            return Int(first)
        }

        let numBytes = Int(first & 0x7F)
        guard numBytes > 0, numBytes <= 4, offset + numBytes <= bytes.count else {
            throw SSHKeyGenerationError.invalidDER
        }

        var length = 0
        for _ in 0..<numBytes {
            length = (length << 8) | Int(bytes[offset])
            offset += 1
        }
        return length
    }

    /// 读取 DER INTEGER 字段并去除正数填充零。
    private static func readDERInteger(_ bytes: [UInt8], _ offset: inout Int) throws -> Data {
        guard offset < bytes.count, bytes[offset] == 0x02 else {
            throw SSHKeyGenerationError.invalidDER
        }
        offset += 1

        let length = try readDERLength(bytes, &offset)
        guard offset + length <= bytes.count else {
            throw SSHKeyGenerationError.invalidDER
        }

        var start = offset
        var len = length

        // 去除 ASN.1 正整数的前置零字节
        if len > 1 && bytes[start] == 0x00 {
            start += 1
            len -= 1
        }

        let data = Data(bytes[start..<(start + len)])
        offset += length
        return data
    }
}

// MARK: - Errors

/// SSHKeyGenerationError：密钥生成过程中的错误。
nonisolated enum SSHKeyGenerationError: LocalizedError {
    case rsaKeyGenerationFailed(String)
    case rsaKeyExportFailed(String)
    case invalidDER

    var errorDescription: String? {
        switch self {
        case .rsaKeyGenerationFailed(let detail):
            return String(localized: "RSA key generation failed: \(detail)")
        case .rsaKeyExportFailed(let detail):
            return String(localized: "RSA key export failed: \(detail)")
        case .invalidDER:
            return String(localized: "Invalid key structure (DER parse error)")
        }
    }
}
