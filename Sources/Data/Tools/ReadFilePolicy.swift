/// 文件说明：ReadFilePolicy，read_file 的敏感路径、体积上限、二进制判断与行号修正。
import Foundation

/// ReadFilePolicy：
/// 读取前的纯判断：敏感路径要确认，超限与二进制内容拒绝装入内存，
/// 行号至少从 1 开始，避免 `sed -n '0,...p'`。
nonisolated enum ReadFilePolicy {
    /// 单次读入内存的上限（1 MiB）。
    static let maxBytes = 1_048_576
    /// 判断是否为二进制时只看的前缀长度。
    static let probeBytes = 8_192

    /// 敏感路径需要用户确认后才能读。
    static func isSensitivePath(_ path: String) -> Bool {
        let lowered = path.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lowered.isEmpty else { return false }
        let base = (lowered as NSString).lastPathComponent

        if base == ".env" || base.hasPrefix(".env.") { return true }
        if base.hasSuffix(".pem") || base.hasSuffix(".key") { return true }
        if base == "authorized_keys" || base == "authorized_keys2" { return true }

        let etcSecrets = [
            "/etc/shadow", "/etc/shadow-", "/etc/gshadow", "/etc/gshadow-",
            "/etc/master.passwd", "/etc/security/opasswd",
        ]
        if etcSecrets.contains(where: { lowered == $0 || lowered.hasSuffix($0) }) { return true }

        if lowered.contains(".ssh/id_") { return true }
        let keyNames = ["id_rsa", "id_dsa", "id_ecdsa", "id_ed25519"]
        if keyNames.contains(where: { base == $0 || base.hasPrefix($0 + ".") }) { return true }
        return false
    }

    /// 含 NUL，或去掉至多 3 字节的截断尾巴后仍不是合法 UTF-8，视为二进制。
    static func looksBinary(_ data: Data) -> Bool {
        if data.isEmpty { return false }
        if data.contains(0) { return true }
        if String(data: data, encoding: .utf8) != nil { return false }
        let limit = min(3, data.count - 1)
        guard limit >= 1 else { return true }
        for drop in 1...limit {
            if String(data: data.dropLast(drop), encoding: .utf8) != nil { return false }
        }
        return true
    }

    /// 起始行小于 1 时改为 1；结束行小于 1，或结束小于起始时抛错。
    static func normalizedBounds(start: Int?, end: Int?) throws -> (start: Int?, end: Int?) {
        let normalizedStart = start.map { max(1, $0) }
        if let end, end < 1 {
            throw ToolError.invalidArguments("end_line must be >= 1")
        }
        if let normalizedStart, let end, end < normalizedStart {
            throw ToolError.invalidArguments("end_line must be greater than or equal to start_line")
        }
        return (normalizedStart, end)
    }

    /// 按行读取的远端命令。输出再经 `head -c` 限制体积。
    static func lineCommand(path: String, start: Int?, end: Int?) throws -> String {
        let bounds = try normalizedBounds(start: start, end: end)
        let escaped = shellEscape(path)
        let body: String
        if let start = bounds.start, let end = bounds.end {
            body = "sed -n '\(start),\(end)p' \(escaped)"
        } else if let start = bounds.start {
            body = "tail -n +\(start) \(escaped)"
        } else if let end = bounds.end {
            body = "head -n \(end) \(escaped)"
        } else {
            throw ToolError.invalidArguments("line range requires start_line or end_line")
        }
        return "\(body) | head -c \(maxBytes)"
    }

    /// 超限时给模型的说明。
    static func tooLargeMessage(byteCount: UInt64) -> String {
        "File is \(byteCount) bytes, which exceeds the \(maxBytes) byte read limit. Use start_line and end_line to read a range."
    }

    /// 二进制拒绝说明。显式 base64 且未超限时才允许读取。
    static let binaryMessage = "File looks binary. Refusing to load it. Request encoding=base64 if you need the bytes (still capped at \(maxBytes) bytes)."
}
