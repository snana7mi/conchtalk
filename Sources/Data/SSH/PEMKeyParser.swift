import Foundation
import CCryptoBoringSSL
import CommonCrypto

/// Parses traditional PEM format private keys (PKCS#1 RSA).
/// Citadel only supports OpenSSH format natively; this extends support to legacy PEM.
nonisolated enum PEMKeyParser {

    /// Check if the key string is in PEM format (not OpenSSH)
    static func isPEMFormat(_ keyString: String) -> Bool {
        let t = keyString.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.hasPrefix("-----BEGIN RSA PRIVATE KEY-----") ||
               t.hasPrefix("-----BEGIN PRIVATE KEY-----") ||
               t.hasPrefix("-----BEGIN ENCRYPTED PRIVATE KEY-----")
    }

    /// Parse a PEM RSA private key and return the raw key components (n, e, d).
    static func parseRSAKeyBytes(pemString: String, passphrase: String?) throws -> (n: [UInt8], e: [UInt8], d: [UInt8]) {
        let (derData, encryption) = try extractPEMBody(pemString)

        let keyDER: Data
        if let encryption {
            guard let passphrase, !passphrase.isEmpty else {
                throw PEMParseError.passphraseRequired
            }
            keyDER = try decryptPEM(derData, encryption: encryption, passphrase: passphrase)
        } else {
            keyDER = derData
        }

        // Parse PKCS#1 ASN.1 DER → (n, e, d)
        let rsa = try parsePKCS1(keyDER)
        return (n: Array(rsa.n), e: Array(rsa.e), d: Array(rsa.d))
    }

    // MARK: - PEM Envelope

    struct PEMEncryption: Sendable {
        let cipher: String
        let iv: [UInt8]
    }

    /// Strip PEM headers, detect encryption, decode base64.
    private static func extractPEMBody(_ pem: String) throws -> (Data, PEMEncryption?) {
        var lines = pem.components(separatedBy: .newlines)

        // Remove header/footer lines
        lines.removeAll { $0.hasPrefix("-----") }

        // Check for OpenSSL-style encryption headers
        var encryption: PEMEncryption? = nil
        var dataStartIndex = 0

        if lines.first?.hasPrefix("Proc-Type:") == true {
            var cipherName: String?
            var ivHex: String?

            for (i, line) in lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty {
                    dataStartIndex = i + 1
                    break
                }
                if trimmed.hasPrefix("DEK-Info:") {
                    let info = trimmed.dropFirst("DEK-Info:".count).trimmingCharacters(in: .whitespaces)
                    let parts = info.split(separator: ",", maxSplits: 1)
                    if parts.count == 2 {
                        cipherName = String(parts[0])
                        ivHex = String(parts[1]).trimmingCharacters(in: .whitespaces)
                    }
                }
            }

            if let cipherName, let ivHex, let iv = hexToBytes(ivHex) {
                encryption = PEMEncryption(cipher: cipherName, iv: iv)
            }
        }

        let base64String = lines[dataStartIndex...].joined()
        guard let data = Data(base64Encoded: base64String, options: .ignoreUnknownCharacters) else {
            throw PEMParseError.invalidBase64
        }

        return (data, encryption)
    }

    // MARK: - PEM Decryption (legacy OpenSSL encryption)

    /// Decrypt PEM-encrypted data using EVP_BytesToKey key derivation + cipher.
    private static func decryptPEM(_ data: Data, encryption: PEMEncryption, passphrase: String) throws -> Data {
        let passphraseBytes = Array(passphrase.utf8)
        let salt = Array(encryption.iv.prefix(8))

        let (keyLen, algorithm): (Int, CCAlgorithm)
        let blockSize: Int
        switch encryption.cipher {
        case "AES-128-CBC":
            keyLen = 16; algorithm = CCAlgorithm(kCCAlgorithmAES); blockSize = kCCBlockSizeAES128
        case "AES-256-CBC":
            keyLen = 32; algorithm = CCAlgorithm(kCCAlgorithmAES); blockSize = kCCBlockSizeAES128
        case "DES-EDE3-CBC":
            keyLen = 24; algorithm = CCAlgorithm(kCCAlgorithm3DES); blockSize = kCCBlockSize3DES
        default:
            throw PEMParseError.unsupportedCipher(encryption.cipher)
        }

        // EVP_BytesToKey with MD5
        let derivedKey = evpBytesToKey(password: passphraseBytes, salt: salt, keyLen: keyLen)

        // Decrypt with CommonCrypto
        var outBuffer = [UInt8](repeating: 0, count: data.count + blockSize)
        var outLength = 0

        let status = data.withUnsafeBytes { dataPtr in
            CCCrypt(
                CCOperation(kCCDecrypt),
                algorithm,
                0,
                derivedKey, keyLen,
                encryption.iv,
                dataPtr.baseAddress, data.count,
                &outBuffer, outBuffer.count,
                &outLength
            )
        }

        guard status == kCCSuccess else {
            throw PEMParseError.decryptionFailed
        }

        return Data(outBuffer.prefix(outLength))
    }

    /// EVP_BytesToKey with MD5 — the key derivation OpenSSL uses for encrypted PEM files.
    private static func evpBytesToKey(password: [UInt8], salt: [UInt8], keyLen: Int) -> [UInt8] {
        var derived = [UInt8]()
        var previousHash = [UInt8]()

        while derived.count < keyLen {
            let input = previousHash + password + salt
            // Use BoringSSL's MD5 (avoids CommonCrypto CC_MD5 deprecation)
            var hash = [UInt8](repeating: 0, count: 16)
            _ = input.withUnsafeBufferPointer { buf in
                CCryptoBoringSSL_MD5(buf.baseAddress, buf.count, &hash)
            }
            previousHash = hash
            derived.append(contentsOf: hash)
        }

        return Array(derived.prefix(keyLen))
    }

    // MARK: - ASN.1 DER Parser (PKCS#1 RSA)

    /// Parse PKCS#1 RSAPrivateKey DER:
    /// SEQUENCE { version, n, e, d, p, q, dp, dq, qinv }
    private static func parsePKCS1(_ data: Data) throws -> (n: Data, e: Data, d: Data) {
        let bytes = Array(data)
        var offset = 0

        // SEQUENCE
        guard offset < bytes.count, bytes[offset] == 0x30 else {
            throw PEMParseError.invalidASN1
        }
        offset += 1
        _ = try readDERLength(bytes, &offset)

        // version INTEGER (should be 0)
        _ = try readDERInteger(bytes, &offset)

        // modulus (n)
        let n = try readDERInteger(bytes, &offset)

        // publicExponent (e)
        let e = try readDERInteger(bytes, &offset)

        // privateExponent (d)
        let d = try readDERInteger(bytes, &offset)

        // We don't need p, q, dp, dq, qinv for Citadel's RSA key
        return (n: n, e: e, d: d)
    }

    /// Read ASN.1 DER length encoding
    private static func readDERLength(_ bytes: [UInt8], _ offset: inout Int) throws -> Int {
        guard offset < bytes.count else { throw PEMParseError.invalidASN1 }

        let first = bytes[offset]
        offset += 1

        if first & 0x80 == 0 {
            return Int(first)
        }

        let numBytes = Int(first & 0x7F)
        guard numBytes > 0, numBytes <= 4, offset + numBytes <= bytes.count else {
            throw PEMParseError.invalidASN1
        }

        var length = 0
        for _ in 0..<numBytes {
            length = (length << 8) | Int(bytes[offset])
            offset += 1
        }
        return length
    }

    /// Read ASN.1 DER INTEGER, strip leading zero byte
    private static func readDERInteger(_ bytes: [UInt8], _ offset: inout Int) throws -> Data {
        guard offset < bytes.count, bytes[offset] == 0x02 else {
            throw PEMParseError.invalidASN1
        }
        offset += 1

        let length = try readDERLength(bytes, &offset)
        guard offset + length <= bytes.count else {
            throw PEMParseError.invalidASN1
        }

        var start = offset
        var len = length

        // Strip leading zero byte (ASN.1 uses it for positive integers with high bit set)
        if len > 1 && bytes[start] == 0x00 {
            start += 1
            len -= 1
        }

        let data = Data(bytes[start..<(start + len)])
        offset += length
        return data
    }

    // MARK: - Hex Utilities

    private static func hexToBytes(_ hex: String) -> [UInt8]? {
        let hex = hex.trimmingCharacters(in: .whitespaces)
        guard hex.count % 2 == 0 else { return nil }

        var bytes = [UInt8]()
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex

        while index < hex.endIndex {
            let nextIndex = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<nextIndex], radix: 16) else { return nil }
            bytes.append(byte)
            index = nextIndex
        }
        return bytes
    }
}

// MARK: - Errors

nonisolated enum PEMParseError: LocalizedError {
    case invalidBase64
    case invalidASN1
    case passphraseRequired
    case decryptionFailed
    case unsupportedCipher(String)
    case unsupportedFormat

    var errorDescription: String? {
        switch self {
        case .invalidBase64: return String(localized: "Invalid base64 in PEM key")
        case .invalidASN1: return String(localized: "Invalid key structure (ASN.1 parse error)")
        case .passphraseRequired: return String(localized: "This key is encrypted. Please provide a passphrase.")
        case .decryptionFailed: return String(localized: "Failed to decrypt key. Wrong passphrase?")
        case .unsupportedCipher(let c): return String(localized: "Unsupported encryption cipher: \(c)")
        case .unsupportedFormat: return String(localized: "Unsupported PEM key format")
        }
    }
}
