/// 文件说明：HostKeyTrust，主机密钥确认所需的值类型（指纹、准入、提交）。
import Foundation

/// KnownHostRecord：已信任的主机密钥记录，供管理页列出与删除。
nonisolated struct KnownHostRecord: Identifiable, Sendable, Equatable {
    var id: String { "\(host)\n\(port)" }
    let host: String
    let port: Int
    /// SHA-256 摘要的小写十六进制。展示时用 `HostKeyFingerprint.openSSH`。
    let fingerprint: String
    let addedAt: Date
}

/// HostKeyAdmission：一次握手里，收到的指纹相对已存储指纹的结论。只读，不写入。
nonisolated enum HostKeyAdmission: Sendable, Equatable {
    /// 与已存储指纹一致，可以直接继续握手。
    case trusted
    /// 从未见过该主机。指纹必须先给用户确认，确认前不得写入。
    case firstUse(fingerprint: String)
    /// 指纹变了。`stored` 是旧指纹，`received` 是这次的指纹。
    case changed(stored: String, received: String)
}

/// HostKeyCommit：用户确认后的一次性写入。调用方必须在同一临界区内比对当前记录再落盘。
nonisolated enum HostKeyCommit: Sendable, Equatable {
    /// 仅当该主机仍没有记录，或记录已经是这枚指纹时成功。
    case trustFirstUse(fingerprint: String)
    /// 仅当当前记录等于 `expectedStored` 时，替换为 `fingerprint`。
    case reset(expectedStored: String, fingerprint: String)
}

/// HostKeyCommitResult：原子提交的结果。冲突时不覆盖已有指纹。
nonisolated enum HostKeyCommitResult: Sendable, Equatable {
    case trusted
    case conflict(HostKeyAdmission)
}

/// HostKeyPromptDecision：用户对指纹确认框的选择。
nonisolated enum HostKeyPromptDecision: Sendable, Equatable {
    case accept
    case reject
}

/// HostKeyPrompt：交给界面的一次确认请求。
nonisolated struct HostKeyPrompt: Identifiable, Sendable, Equatable {
    let id: UUID
    let host: String
    let port: Int
    let admission: HostKeyAdmission

    var endpoint: String { "\(host):\(port)" }
}

/// HostKeyFingerprint：把存储用的十六进制 SHA-256 显示成 OpenSSH 的 `SHA256:` 形式。
nonisolated enum HostKeyFingerprint {
    /// `SHA256:` + 无填充 Base64。无法解析时退回 `SHA256:` 加原始文本，避免把坏数据伪装成空指纹。
    static func openSSH(hex: String) -> String {
        let cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned.count.isMultiple(of: 2) else {
            return "SHA256:\(cleaned)"
        }
        var bytes = [UInt8]()
        bytes.reserveCapacity(cleaned.count / 2)
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            let pair = cleaned[index..<next]
            guard let byte = UInt8(pair, radix: 16) else {
                return "SHA256:\(cleaned)"
            }
            bytes.append(byte)
            index = next
        }
        let encoded = Data(bytes).base64EncodedString().replacingOccurrences(of: "=", with: "")
        return "SHA256:\(encoded)"
    }
}
