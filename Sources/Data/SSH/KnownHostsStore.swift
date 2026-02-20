/// 文件说明：KnownHostsStore，提供 SSH 主机密钥指纹的持久化存储与验证（TOFU 模型）。
import Foundation
import Citadel
import Crypto
import NIOSSH
import NIOCore

// MARK: - Known Host Status

/// KnownHostStatus：主机密钥查询结果，描述当前主机密钥与已存储指纹的匹配关系。
enum KnownHostStatus: Sendable {
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
/// 采用 Trust On First Use（TOFU）策略：首次连接自动信任并记录指纹，
/// 后续连接校验指纹是否一致。
///
/// - Note: 使用 actor 隔离保证线程安全。
actor KnownHostsStore {

    /// 单条主机指纹记录。
    private struct HostEntry: Codable, Sendable {
        let host: String
        let port: Int
        let fingerprint: String
        let addedAt: Date
    }

    /// 内存中的指纹表，键为 "host:port" 格式。
    private var entries: [String: HostEntry] = [:]

    /// 持久化文件路径。
    private let fileURL: URL

    // MARK: - Initialization

    /// 使用指定文件路径初始化，并加载已有的指纹数据。
    /// - Parameter fileURL: 指纹数据 JSON 文件路径；传 `nil` 时使用默认路径。
    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL
        self.entries = Self.loadEntries(from: self.fileURL)
    }

    /// 默认存储路径：`<AppDocuments>/known_hosts.json`。
    nonisolated private static var defaultFileURL: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return documents.appendingPathComponent("known_hosts.json")
    }

    // MARK: - Public API

    /// 查询指定主机的密钥指纹状态。
    /// - Parameters:
    ///   - host: 主机地址。
    ///   - port: 端口号。
    ///   - fingerprint: 本次收到的指纹。
    /// - Returns: 匹配状态。
    func lookup(host: String, port: Int, fingerprint: String) -> KnownHostStatus {
        let key = Self.entryKey(host: host, port: port)
        guard let existing = entries[key] else {
            return .unknown
        }
        if existing.fingerprint == fingerprint {
            return .matched
        }
        return .mismatch(stored: existing.fingerprint, received: fingerprint)
    }

    /// 存储主机密钥指纹（覆盖已有记录）。
    /// - Parameters:
    ///   - host: 主机地址。
    ///   - port: 端口号。
    ///   - fingerprint: 指纹字符串（SHA-256 十六进制）。
    func store(host: String, port: Int, fingerprint: String) {
        let key = Self.entryKey(host: host, port: port)
        entries[key] = HostEntry(host: host, port: port, fingerprint: fingerprint, addedAt: Date())
        persist()
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

    /// 将当前内存中的指纹表写入磁盘。
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

    /// 构建内部查询键。
    nonisolated private static func entryKey(host: String, port: Int) -> String {
        "\(host):\(port)"
    }
}

// MARK: - SSHHostKeyValidator Integration

extension KnownHostsStore {

    /// 创建基于本 store 的 Citadel `SSHHostKeyValidator`（TOFU 策略）。
    /// - Parameters:
    ///   - host: 目标主机。
    ///   - port: 目标端口。
    /// - Returns: 可直接传入 `SSHClient.connect` 的校验器。
    func makeValidator(host: String, port: Int) -> SSHHostKeyValidator {
        // 捕获 self（actor）引用，在 EventLoop 回调中通过 Task 桥接 actor 隔离。
        let store = self
        let validator = TOFUHostKeyValidator(store: store, host: host, port: port)
        return .custom(validator)
    }
}

/// TOFUHostKeyValidator：
/// 实现 `NIOSSHClientServerAuthenticationDelegate`，在 EventLoop promise 回调中
/// 桥接 actor 调用完成 TOFU 校验。
private final class TOFUHostKeyValidator: @preconcurrency NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    private let store: KnownHostsStore
    private let host: String
    private let port: Int

    nonisolated init(store: KnownHostsStore, host: String, port: Int) {
        self.store = store
        self.host = host
        self.port = port
    }

    nonisolated func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let fingerprint = KnownHostsStore.fingerprint(of: hostKey)
        let host = self.host
        let port = self.port
        let store = self.store

        Task {
            let status = await store.lookup(host: host, port: port, fingerprint: fingerprint)
            switch status {
            case .unknown:
                // TOFU：首次连接自动信任
                await store.store(host: host, port: port, fingerprint: fingerprint)
                validationCompletePromise.succeed(())
            case .matched:
                validationCompletePromise.succeed(())
            case .mismatch(let stored, let received):
                validationCompletePromise.fail(
                    SSHError.hostKeyMismatch(host: host, stored: stored, received: received)
                )
            }
        }
    }
}
