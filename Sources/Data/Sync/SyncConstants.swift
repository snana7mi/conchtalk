/// 文件说明：SyncConstants，定义云同步所需的常量和实体类型枚举。
import Foundation

/// SyncEntityType：可同步的实体类型枚举。
enum SyncEntityType: String, CaseIterable, Codable, Sendable {
    case server
    case message
    case sshKey = "ssh_key"
    case serverGroup = "server_group"
    case memory
    case memoryEntry = "memory_entry"
    case systemProfile = "system_profile"

    /// 全量恢复时的拉取优先级（数字越小越先拉取）。
    /// ServerGroup 必须在 Server 之前，确保分组关系能正确重建。
    var pullPriority: Int {
        switch self {
        case .serverGroup: 0
        case .sshKey: 1
        case .server: 2
        case .message: 3
        case .memory: 4
        case .memoryEntry: 5
        case .systemProfile: 6
        }
    }
}

/// SyncVersionCounter：全局同步版本原子计数器。
/// 使用 actor 保证线程安全，UserDefaults 持久化。
actor SyncVersionCounter {
    static let shared = SyncVersionCounter()
    private let key = "SyncVersionCounter.current"

    func next() -> Int64 {
        let current = UserDefaults.standard.value(forKey: key) as? Int64 ?? 0
        let next = current + 1
        UserDefaults.standard.set(next, forKey: key)
        return next
    }

    var current: Int64 {
        UserDefaults.standard.value(forKey: key) as? Int64 ?? 0
    }
}

/// SyncState：同步进度持久化。
/// 所有属性标记 nonisolated(unsafe) 以便 SyncService（非 MainActor 的 actor）可以直接访问。
/// UserDefaults 本身线程安全，此处的竞态风险可接受。
enum SyncState {
    private nonisolated static let lastSyncedVersionKey = "SyncState.lastSyncedVersion"
    private nonisolated static let syncEnabledKey = "SyncState.enabled"
    private nonisolated static let disabledByUserKey = "SyncState.disabledByUserID"
    private nonisolated static let deviceIdKey = "SyncState.deviceId"
    private nonisolated static let keyGenerationKey = "SyncState.keyGeneration"

    nonisolated(unsafe) static var lastSyncedVersion: Int64 {
        get { UserDefaults.standard.value(forKey: lastSyncedVersionKey) as? Int64 ?? 0 }
        set { UserDefaults.standard.set(newValue, forKey: lastSyncedVersionKey) }
    }

    private nonisolated static let lastPulledSeqKey = "SyncState.lastPulledSeq"

    /// pull 游标：已拉取到的最大服务端 seq。0 表示从未拉取过（或已重置）。
    nonisolated(unsafe) static var lastPulledSeq: Int64 {
        get { UserDefaults.standard.value(forKey: lastPulledSeqKey) as? Int64 ?? 0 }
        set { UserDefaults.standard.set(newValue, forKey: lastPulledSeqKey) }
    }

    nonisolated(unsafe) static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: syncEnabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: syncEnabledKey) }
    }

    /// 记录主动关闭同步的用户 ID（per-user 语义，防止跨账户误判）。
    /// nil 表示没有用户主动关闭过，或已被当前用户重新开启。
    nonisolated(unsafe) static var disabledByUserID: String? {
        get { UserDefaults.standard.string(forKey: disabledByUserKey) }
        set { UserDefaults.standard.set(newValue, forKey: disabledByUserKey) }
    }

    nonisolated(unsafe) static var deviceId: String {
        get {
            if let existing = UserDefaults.standard.string(forKey: deviceIdKey) {
                return existing
            }
            let newId = UUID().uuidString
            UserDefaults.standard.set(newId, forKey: deviceIdKey)
            return newId
        }
    }

    nonisolated(unsafe) static var keyGeneration: Int {
        get { UserDefaults.standard.integer(forKey: keyGenerationKey).nonZero ?? 1 }
        set { UserDefaults.standard.set(newValue, forKey: keyGenerationKey) }
    }

    nonisolated static func reset() {
        lastSyncedVersion = 0
        lastPulledSeq = 0
    }
}

/// SyncGarbageCollector：清理本地已软删除超过 30 天的记录。
/// 在每次同步成功后调用。
enum SyncGarbageCollector {
    static let softDeleteRetentionDays: TimeInterval = 30 * 24 * 60 * 60  // 30 天
}

extension Int {
    nonisolated var nonZero: Int? { self == 0 ? nil : self }
}

extension Notification.Name {
    /// 云同步 pull 到新数据后发送，UI 层监听此通知刷新列表。
    static let syncDidPullNewData = Notification.Name("syncDidPullNewData")
}
