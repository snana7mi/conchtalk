/// 文件说明：RelayActivityTracker，管理 relay 服务器灵动岛的 5 分钟过期计时。

import Foundation

/// RelayActivityTracker：
/// 追踪用户访问过的 relay 服务器，离开聊天页后启动倒计时，
/// 超时自动移除，用于控制灵动岛的生命周期。
@MainActor
@Observable
final class RelayActivityTracker {

    /// 过期时长（秒），默认 5 分钟。
    let expiryInterval: TimeInterval

    /// 回调：当最后一个 server 过期时触发，供外部结束 Live Activity。
    var onAllExpired: (() -> Void)?

    private struct Entry {
        var isInPage: Bool
        var expiryTimer: Task<Void, Never>?
        var serverName: String?
    }

    private var entries: [UUID: Entry] = [:]

    init(expiryInterval: TimeInterval = 300) {
        self.expiryInterval = expiryInterval
    }

    var hasActiveServers: Bool { !entries.isEmpty }
    var activeServerIDs: Set<UUID> { Set(entries.keys) }

    func serverDidEnter(_ serverID: UUID, serverName: String? = nil) {
        var entry = entries[serverID] ?? Entry(isInPage: false)
        entry.expiryTimer?.cancel()
        entry.expiryTimer = nil
        entry.isInPage = true
        if let serverName { entry.serverName = serverName }
        entries[serverID] = entry
    }

    func serverDidLeave(_ serverID: UUID) {
        guard var entry = entries[serverID] else { return }
        entry.isInPage = false
        entry.expiryTimer?.cancel()
        entry.expiryTimer = Task { [weak self, expiryInterval] in
            try? await Task.sleep(for: .seconds(expiryInterval))
            guard !Task.isCancelled else { return }
            self?.expire(serverID)
        }
        entries[serverID] = entry
    }

    func serverName(for serverID: UUID) -> String? {
        entries[serverID]?.serverName
    }

    func removeAll() {
        for entry in entries.values { entry.expiryTimer?.cancel() }
        entries.removeAll()
    }

    func remove(_ serverID: UUID) {
        entries[serverID]?.expiryTimer?.cancel()
        entries.removeValue(forKey: serverID)
        if entries.isEmpty { onAllExpired?() }
    }

    private func expire(_ serverID: UUID) {
        entries.removeValue(forKey: serverID)
        if entries.isEmpty { onAllExpired?() }
    }
}
