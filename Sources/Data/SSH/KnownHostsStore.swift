/// 文件说明：KnownHostsStore，提供 SSH 主机密钥指纹的持久化存储与验证。
import Foundation
import Citadel
import Crypto
import Darwin
import NIOSSH
import NIOCore

// MARK: - Known Host Status

/// KnownHostStatus：主机密钥查询结果，描述当前主机密钥与已存储指纹的匹配关系。
nonisolated enum KnownHostStatus: Sendable, Equatable {
    /// 该主机从未连接过，无已知指纹。
    case unknown
    /// 主机密钥指纹与已存储指纹一致。
    case matched
    /// 主机密钥指纹与已存储指纹不一致（可能遭遇中间人攻击）。
    /// - Parameters:
    ///   - stored: 已存储的指纹（SHA-256 十六进制）。
    ///   - received: 本次收到的指纹（SHA-256 十六进制）。
    case mismatch(stored: String, received: String)
}

// MARK: - KnownHostsStore

/// KnownHostsStore：
/// 基于 JSON 文件持久化的已知主机密钥指纹管理器。
/// 首次连接只报告指纹，等用户确认后才写入；密钥变化时保留旧指纹，直到用户确认重置。
/// 读-改-写包在同一把文件锁里，避免 lookup 和 store 分成两次调用时互相覆盖。
///
/// - Note: 使用 actor 隔离保证同一实例内的调用串行；文件锁覆盖多个实例。
actor KnownHostsStore {

    /// 单条主机指纹记录。
    nonisolated private struct HostEntry: Codable, Sendable {
        let host: String
        let port: Int
        let fingerprint: String
        let addedAt: Date
    }

    /// 内存中的指纹表，键为 "host:port" 格式。每次公开操作都会在锁内重新读盘。
    private var entries: [String: HostEntry] = [:]

    /// 持久化文件路径。
    private let fileURL: URL

    // MARK: - Initialization

    /// 使用指定文件路径初始化，并加载已有的指纹数据。
    /// - Parameter fileURL: 指纹数据 JSON 文件路径；传 `nil` 时使用默认路径。
    init(fileURL: URL? = nil) {
        let url = fileURL ?? Self.defaultFileURL
        self.fileURL = url
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        self.entries = Self.loadEntries(from: url)
    }

    /// 默认存储路径：`<AppDocuments>/known_hosts.json`。
    nonisolated private static var defaultFileURL: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return documents.appendingPathComponent("known_hosts.json")
    }

    // MARK: - Public API

    /// 查询指定主机的密钥指纹状态。不写入。
    func lookup(host: String, port: Int, fingerprint: String) -> KnownHostStatus {
        switch admission(host: host, port: port, fingerprint: fingerprint) {
        case .trusted:
            return .matched
        case .firstUse:
            return .unknown
        case .changed(let stored, let received):
            return .mismatch(stored: stored, received: received)
        }
    }

    /// 只读准入。首次见到和指纹变化都不会落盘。
    func admission(host: String, port: Int, fingerprint: String) -> HostKeyAdmission {
        let fingerprint = Self.normalize(fingerprint)
        return withStore { entries in
            (result: Self.admission(in: entries, host: host, port: port, fingerprint: fingerprint), dirty: false)
        }.result
    }

    /// 原子提交用户已经确认过的指纹。状态对不上时返回冲突，不覆盖。
    func commit(_ action: HostKeyCommit, host: String, port: Int) -> HostKeyCommitResult {
        let key = Self.entryKey(host: host, port: port)
        let outcome: (result: HostKeyCommitResult, dirty: Bool) = withStore { entries in
            switch action {
            case .trustFirstUse(let fingerprint):
                let fingerprint = Self.normalize(fingerprint)
                if let existing = entries[key] {
                    if existing.fingerprint == fingerprint {
                        return (result: .trusted, dirty: false)
                    }
                    return (result: .conflict(.changed(stored: existing.fingerprint, received: fingerprint)), dirty: false)
                }
                entries[key] = HostEntry(host: host, port: port, fingerprint: fingerprint, addedAt: Date())
                return (result: .trusted, dirty: true)

            case .reset(let expectedStored, let fingerprint):
                let expected = Self.normalize(expectedStored)
                let fingerprint = Self.normalize(fingerprint)
                guard let existing = entries[key] else {
                    return (result: .conflict(.firstUse(fingerprint: fingerprint)), dirty: false)
                }
                guard existing.fingerprint == expected else {
                    return (result: .conflict(.changed(stored: existing.fingerprint, received: fingerprint)), dirty: false)
                }
                if existing.fingerprint == fingerprint {
                    return (result: .trusted, dirty: false)
                }
                entries[key] = HostEntry(host: host, port: port, fingerprint: fingerprint, addedAt: Date())
                return (result: .trusted, dirty: true)
            }
        }
        return outcome.result
    }

    /// 已信任的主机，按主机名和端口排序。
    func list() -> [KnownHostRecord] {
        let records = withStore { entries in
            let records = entries.values.map {
                KnownHostRecord(host: $0.host, port: $0.port, fingerprint: $0.fingerprint, addedAt: $0.addedAt)
            }
            return (result: records, dirty: false)
        }.result
        return records.sorted { lhs, rhs in
            if lhs.host == rhs.host { return lhs.port < rhs.port }
            return lhs.host < rhs.host
        }
    }

    /// 移除指定主机的已存储指纹（用于服务器重装后清除旧指纹，或管理页删除）。
    func remove(host: String, port: Int) {
        let key = Self.entryKey(host: host, port: port)
        _ = withStore { entries -> (result: Void, dirty: Bool) in
            let dirty = entries.removeValue(forKey: key) != nil
            return (result: (), dirty: dirty)
        }
    }

    // MARK: - Fingerprint Computation

    /// 从 `NIOSSHPublicKey` 计算 SHA-256 指纹（十六进制字符串）。
    /// - Parameter hostKey: SSH 公钥。
    /// - Returns: SHA-256 指纹的小写十六进制表示。
    nonisolated static func fingerprint(of hostKey: NIOSSHPublicKey) -> String {
        var buffer = ByteBuffer()
        hostKey.write(to: &buffer)
        let data = Data(buffer.readableBytesView)
        let hash = SHA256.hash(data: data)
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Persistence

    /// 锁内读-改-写。`dirty == false` 时不回写，避免只读查询把并发写入覆盖掉。
    private func withStore<T>(_ body: (inout [String: HostEntry]) -> (result: T, dirty: Bool)) -> (result: T, dirty: Bool) {
        let lock = HostKeyFileLock(url: fileURL.appendingPathExtension("lock"))
        defer { withExtendedLifetime(lock) {} }
        var fresh = Self.loadEntries(from: fileURL)
        let outcome = body(&fresh)
        entries = fresh
        if outcome.dirty {
            persist()
        }
        return outcome
    }

    /// 将当前内存中的指纹表写入磁盘。调用方必须已经持有文件锁。
    private func persist() {
        do {
            let allEntries = Array(entries.values)
            let data = try JSONEncoder().encode(allEntries)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("[KnownHostsStore] 持久化失败: \(error)")
        }
    }

    /// 从磁盘加载指纹表。
    /// - Parameter url: JSON 文件路径。
    /// - Returns: 键值对映射；文件不存在或解析失败时返回空字典。
    nonisolated private static func loadEntries(from url: URL) -> [String: HostEntry] {
        guard let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([HostEntry].self, from: data) else {
            return [:]
        }
        var map = [String: HostEntry]()
        for entry in list {
            map[entryKey(host: entry.host, port: entry.port)] = entry
        }
        return map
    }

    nonisolated private static func admission(
        in entries: [String: HostEntry],
        host: String,
        port: Int,
        fingerprint: String
    ) -> HostKeyAdmission {
        let key = entryKey(host: host, port: port)
        guard let existing = entries[key] else {
            return .firstUse(fingerprint: fingerprint)
        }
        if existing.fingerprint == fingerprint {
            return .trusted
        }
        return .changed(stored: existing.fingerprint, received: fingerprint)
    }

    nonisolated private static func normalize(_ fingerprint: String) -> String {
        fingerprint.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// 构建内部查询键。
    nonisolated private static func entryKey(host: String, port: Int) -> String {
        "\(host):\(port)"
    }
}

/// 跨实例的排他锁。进程退出后由系统释放。
nonisolated private final class HostKeyFileLock {
    private let fd: Int32

    init?(url: URL) {
        let fd = Darwin.open(url.path, O_CREAT | O_RDWR, mode_t(0o600))
        guard fd >= 0 else { return nil }
        if flock(fd, LOCK_EX) != 0 {
            Darwin.close(fd)
            return nil
        }
        self.fd = fd
    }

    deinit {
        _ = flock(fd, LOCK_UN)
        Darwin.close(fd)
    }
}

// MARK: - SSHHostKeyValidator Integration

extension KnownHostsStore {

    /// 创建会先向用户展示 SHA256 指纹的主机密钥校验器。
    /// `prompter == nil` 时首次连接和密钥变化都失败，不会静默信任。
    func makeValidator(host: String, port: Int, prompter: (any HostKeyPrompting)?) -> SSHHostKeyValidator {
        let validator = ConfirmingHostKeyValidator(store: self, host: host, port: port, prompter: prompter)
        return .custom(validator)
    }
}
