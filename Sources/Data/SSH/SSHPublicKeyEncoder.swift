/// 文件说明：SSHPublicKeyEncoder，负责 SSH 公钥的 OpenSSH 格式编码、指纹计算及从私钥派生公钥信息。
import Foundation
import CryptoKit

/// SSHPublicKeyEncoder：
/// 提供 SSH 公钥相关的编码与计算功能，包括 OpenSSH 格式序列化、SHA-256 指纹生成，
/// 以及从私钥数据中提取公钥信息。
nonisolated enum SSHPublicKeyEncoder {

    // MARK: - OpenSSH 公钥编码

    /// 将 Ed25519 原始公钥字节编码为 OpenSSH 格式字符串。
    /// - Parameter rawPublicKey: 32 字节 Ed25519 公钥。
    /// - Returns: `"ssh-ed25519 <base64>"` 格式的公钥字符串。
    static func encodeEd25519(rawPublicKey: Data) -> String {
        var blob = Data()
        blob.append(writeSSHString("ssh-ed25519"))
        blob.append(writeSSHBytes(rawPublicKey))
        return "ssh-ed25519 \(blob.base64EncodedString())"
    }

    /// 将 ECDSA P-256 公钥点编码为 OpenSSH 格式字符串。
    /// - Parameter publicKeyPoint: 未压缩的 P-256 公钥点（65 字节，0x04 前缀）。
    /// - Returns: `"ecdsa-sha2-nistp256 <base64>"` 格式的公钥字符串。
    static func encodeECDSAP256(publicKeyPoint: Data) -> String {
        var blob = Data()
        blob.append(writeSSHString("ecdsa-sha2-nistp256"))
        blob.append(writeSSHString("nistp256"))
        blob.append(writeSSHBytes(publicKeyPoint))
        return "ecdsa-sha2-nistp256 \(blob.base64EncodedString())"
    }

    /// 将 RSA 公钥参数编码为 OpenSSH 格式字符串。
    /// - Parameters:
    ///   - e: RSA 公钥指数原始字节。
    ///   - n: RSA 模数原始字节。
    /// - Returns: `"ssh-rsa <base64>"` 格式的公钥字符串。
    static func encodeRSA(e: Data, n: Data) -> String {
        var blob = Data()
        blob.append(writeSSHString("ssh-rsa"))
        blob.append(writeSSHMPInt(e))
        blob.append(writeSSHMPInt(n))
        return "ssh-rsa \(blob.base64EncodedString())"
    }

    // MARK: - 指纹计算

    /// 对公钥 blob 计算 SHA-256 指纹。
    /// - Parameter data: 编码后的公钥 blob 字节（base64 编码前的原始数据）。
    /// - Returns: `"SHA256:<base64_no_padding>"` 格式的指纹字符串。
    static func fingerprint(fromPublicKeyBlob data: Data) -> String {
        let hash = SHA256.hash(data: data)
        let base64 = Data(hash).base64EncodedString()
        // 去除 base64 末尾的 '=' 填充
        let trimmed = base64.replacingOccurrences(of: "=", with: "")
        return "SHA256:\(trimmed)"
    }

    // MARK: - 从私钥派生公钥信息

    /// 从私钥数据中解析并派生公钥的 OpenSSH 字符串与指纹。
    /// 按以下顺序尝试：Ed25519（OpenSSH 格式）→ ECDSA P-256（PEM）→ RSA（PEM）。
    /// - Parameters:
    ///   - data: 私钥的原始数据。
    ///   - passphrase: 私钥口令（加密密钥时需要）。
    /// - Returns: 成功时返回公钥 OpenSSH 字符串、指纹与密钥类型；所有格式均无法解析时返回 `nil`。
    static func derivePublicKeyInfo(
        fromPrivateKeyData data: Data,
        passphrase: String?
    ) -> (publicKeyOpenSSH: String, fingerprint: String, keyType: SSHKey.KeyType)? {
        guard let keyString = String(data: data, encoding: .utf8) else { return nil }

        // 1. Ed25519 OpenSSH 格式
        if let result = deriveEd25519PublicKey(from: data) {
            return result
        }

        // 2. ECDSA P-256 PEM
        if let result = deriveP256PublicKey(from: keyString) {
            return result
        }

        // 3. RSA PEM
        if let result = deriveRSAPublicKey(from: keyString, passphrase: passphrase) {
            return result
        }

        // 4. OpenSSH RSA（非 PEM，Citadel 的 ssh-rsa 格式）
        if let result = deriveOpenSSHRSAPublicKey(from: data) {
            return result
        }

        return nil
    }

    // MARK: - Ed25519 公钥提取

    /// 从 OpenSSH 格式的 Ed25519 私钥中提取公钥。
    /// 查找 `openssh-key-v1\0` 魔数字节，解析公钥段获取 32 字节 Ed25519 公钥。
    /// - Parameter data: 私钥原始数据。
    /// - Returns: 成功时返回公钥信息三元组。
    private static func deriveEd25519PublicKey(
        from data: Data
    ) -> (publicKeyOpenSSH: String, fingerprint: String, keyType: SSHKey.KeyType)? {
        // 检查 OpenSSH 私钥魔数
        let magic = "openssh-key-v1\0"
        guard let keyString = String(data: data, encoding: .utf8),
              keyString.contains("BEGIN OPENSSH PRIVATE KEY") else {
            return nil
        }

        // 提取 base64 主体
        let lines = keyString.components(separatedBy: .newlines)
        let base64Lines = lines.filter { !$0.hasPrefix("-----") && !$0.isEmpty }
        let base64String = base64Lines.joined()
        guard let binaryData = Data(base64Encoded: base64String, options: .ignoreUnknownCharacters) else {
            return nil
        }

        let bytes = Array(binaryData)
        let magicBytes = Array(magic.utf8)

        // 验证魔数
        guard bytes.count > magicBytes.count,
              Array(bytes.prefix(magicBytes.count)) == magicBytes else {
            return nil
        }

        var offset = magicBytes.count

        // 跳过 cipher (string)
        guard let _ = readSSHString(bytes, &offset) else { return nil }
        // 跳过 kdf (string)
        guard let _ = readSSHString(bytes, &offset) else { return nil }
        // 跳过 kdf options (string)
        guard let _ = readSSHString(bytes, &offset) else { return nil }

        // 读取密钥数量 (uint32)
        guard offset + 4 <= bytes.count else { return nil }
        offset += 4  // number of keys

        // 读取公钥 blob (string)
        guard let publicKeyBlob = readSSHBytes(bytes, &offset) else { return nil }

        // 解析公钥 blob 内部：string "ssh-ed25519" + string <32-byte pubkey>
        var blobOffset = 0
        let blobBytes = Array(publicKeyBlob)
        guard let keyType = readSSHString(blobBytes, &blobOffset) else { return nil }
        guard keyType == "ssh-ed25519" else { return nil }
        guard let rawPubKey = readSSHBytes(blobBytes, &blobOffset) else { return nil }
        guard rawPubKey.count == 32 else { return nil }

        let publicKeyOpenSSH = encodeEd25519(rawPublicKey: Data(rawPubKey))
        let fp = fingerprint(fromPublicKeyBlob: Data(publicKeyBlob))
        return (publicKeyOpenSSH: publicKeyOpenSSH, fingerprint: fp, keyType: .ed25519)
    }

    // MARK: - ECDSA P-256 公钥提取

    /// 从 PEM 格式的 P-256 私钥中派生公钥。
    /// - Parameter keyString: PEM 格式私钥文本。
    /// - Returns: 成功时返回公钥信息三元组。
    private static func deriveP256PublicKey(
        from keyString: String
    ) -> (publicKeyOpenSSH: String, fingerprint: String, keyType: SSHKey.KeyType)? {
        guard let privateKey = try? P256.Signing.PrivateKey(pemRepresentation: keyString) else {
            return nil
        }
        let publicPoint = Data(privateKey.publicKey.x963Representation)
        let publicKeyOpenSSH = encodeECDSAP256(publicKeyPoint: publicPoint)

        // 构建公钥 blob 用于指纹计算
        var blob = Data()
        blob.append(writeSSHString("ecdsa-sha2-nistp256"))
        blob.append(writeSSHString("nistp256"))
        blob.append(writeSSHBytes(publicPoint))

        let fp = fingerprint(fromPublicKeyBlob: blob)
        return (publicKeyOpenSSH: publicKeyOpenSSH, fingerprint: fp, keyType: .ecdsaP256)
    }

    // MARK: - RSA 公钥提取

    /// 从 PEM 格式的 RSA 私钥中派生公钥。
    /// 使用 `PEMKeyParser` 提取 n、e 参数后编码为 ssh-rsa 格式。
    /// - Parameters:
    ///   - keyString: PEM 格式私钥文本。
    ///   - passphrase: 私钥口令。
    /// - Returns: 成功时返回公钥信息三元组。
    private static func deriveRSAPublicKey(
        from keyString: String,
        passphrase: String?
    ) -> (publicKeyOpenSSH: String, fingerprint: String, keyType: SSHKey.KeyType)? {
        guard PEMKeyParser.isPEMFormat(keyString) else { return nil }
        guard let (n, e, _) = try? PEMKeyParser.parseRSAKeyBytes(pemString: keyString, passphrase: passphrase) else {
            return nil
        }

        let eData = Data(e)
        let nData = Data(n)
        let publicKeyOpenSSH = encodeRSA(e: eData, n: nData)

        // 构建公钥 blob 用于指纹计算
        var blob = Data()
        blob.append(writeSSHString("ssh-rsa"))
        blob.append(writeSSHMPInt(eData))
        blob.append(writeSSHMPInt(nData))

        let fp = fingerprint(fromPublicKeyBlob: blob)
        return (publicKeyOpenSSH: publicKeyOpenSSH, fingerprint: fp, keyType: .rsa4096)
    }

    // MARK: - OpenSSH RSA 公钥提取

    /// 从 OpenSSH 格式的 RSA 私钥中提取公钥。
    /// 解析 `openssh-key-v1` 结构中的公钥 blob，提取 ssh-rsa 的 e 和 n 参数。
    /// - Parameter data: 私钥原始数据。
    /// - Returns: 成功时返回公钥信息三元组。
    private static func deriveOpenSSHRSAPublicKey(
        from data: Data
    ) -> (publicKeyOpenSSH: String, fingerprint: String, keyType: SSHKey.KeyType)? {
        guard let keyString = String(data: data, encoding: .utf8),
              keyString.contains("BEGIN OPENSSH PRIVATE KEY") else {
            return nil
        }

        let lines = keyString.components(separatedBy: .newlines)
        let base64Lines = lines.filter { !$0.hasPrefix("-----") && !$0.isEmpty }
        let base64String = base64Lines.joined()
        guard let binaryData = Data(base64Encoded: base64String, options: .ignoreUnknownCharacters) else {
            return nil
        }

        let bytes = Array(binaryData)
        let magic = "openssh-key-v1\0"
        let magicBytes = Array(magic.utf8)

        guard bytes.count > magicBytes.count,
              Array(bytes.prefix(magicBytes.count)) == magicBytes else {
            return nil
        }

        var offset = magicBytes.count

        // 跳过 cipher, kdf, kdf options
        guard let _ = readSSHString(bytes, &offset) else { return nil }
        guard let _ = readSSHString(bytes, &offset) else { return nil }
        guard let _ = readSSHString(bytes, &offset) else { return nil }

        // 密钥数量
        guard offset + 4 <= bytes.count else { return nil }
        offset += 4

        // 读取公钥 blob
        guard let publicKeyBlob = readSSHBytes(bytes, &offset) else { return nil }

        // 解析公钥 blob: string key_type + ...
        var blobOffset = 0
        let blobBytes = Array(publicKeyBlob)
        guard let keyType = readSSHString(blobBytes, &blobOffset) else { return nil }
        guard keyType == "ssh-rsa" else { return nil }

        // ssh-rsa 公钥 blob: string "ssh-rsa" + mpint e + mpint n
        guard let eBytes = readSSHBytes(blobBytes, &blobOffset) else { return nil }
        guard let nBytes = readSSHBytes(blobBytes, &blobOffset) else { return nil }

        let eData = Data(eBytes)
        let nData = Data(nBytes)
        let publicKeyOpenSSH = encodeRSA(e: eData, n: nData)
        let fp = fingerprint(fromPublicKeyBlob: Data(publicKeyBlob))
        return (publicKeyOpenSSH: publicKeyOpenSSH, fingerprint: fp, keyType: .rsa4096)
    }

    // MARK: - SSH Wire Format 辅助方法

    /// 按 SSH wire format 编码字符串：4 字节大端长度前缀 + UTF-8 字节。
    /// - Parameter string: 待编码字符串。
    /// - Returns: 编码后的数据。
    private static func writeSSHString(_ string: String) -> Data {
        let bytes = Data(string.utf8)
        return writeSSHBytes(bytes)
    }

    /// 按 SSH wire format 编码字节序列：4 字节大端长度前缀 + 原始字节。
    /// - Parameter bytes: 待编码字节。
    /// - Returns: 编码后的数据。
    private static func writeSSHBytes(_ bytes: Data) -> Data {
        var data = Data()
        var length = UInt32(bytes.count).bigEndian
        data.append(Data(bytes: &length, count: 4))
        data.append(bytes)
        return data
    }

    /// 按 SSH mpint 格式编码大整数：正数最高位为 1 时补零字节。
    /// - Parameter value: 大整数原始字节（无符号，大端序）。
    /// - Returns: SSH wire format 编码后的数据。
    private static func writeSSHMPInt(_ value: Data) -> Data {
        var bytes = value
        // 正整数最高位为 1 时，需要前置 0x00 避免被解释为负数
        if let first = bytes.first, first & 0x80 != 0 {
            bytes.insert(0x00, at: 0)
        }
        return writeSSHBytes(bytes)
    }

    // MARK: - SSH Wire Format 读取辅助

    /// 从字节流中读取 SSH string（4 字节长度 + UTF-8 数据）。
    /// - Parameters:
    ///   - bytes: 字节数组。
    ///   - offset: 当前偏移，读取后自动推进。
    /// - Returns: 解码后的字符串，失败返回 `nil`。
    private static func readSSHString(_ bytes: [UInt8], _ offset: inout Int) -> String? {
        guard let data = readSSHBytes(bytes, &offset) else { return nil }
        return String(bytes: data, encoding: .utf8)
    }

    /// 从字节流中读取 SSH bytes（4 字节长度 + 原始数据）。
    /// - Parameters:
    ///   - bytes: 字节数组。
    ///   - offset: 当前偏移，读取后自动推进。
    /// - Returns: 原始字节数组，失败返回 `nil`。
    private static func readSSHBytes(_ bytes: [UInt8], _ offset: inout Int) -> [UInt8]? {
        guard offset + 4 <= bytes.count else { return nil }
        let length = Int(UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16 |
                         UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3]))
        offset += 4
        guard length >= 0, offset + length <= bytes.count else { return nil }
        let data = Array(bytes[offset..<(offset + length)])
        offset += length
        return data
    }
}
