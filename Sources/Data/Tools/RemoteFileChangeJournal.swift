/// 文件说明：RemoteFileChangeJournal，按服务器记住本会话内 write/edit 的远端快照栈。
import Foundation

/// RemoteFileChangeJournal：
/// 只活在当前进程里。每个路径保留最近若干次快照，供 rollback_file 与审批 diff 使用。
/// 快照字节在远端，这里只记路径和是否可恢复。
actor RemoteFileChangeJournal {
    /// 进程内共享日记。工具和审批预览默认用它，这样同一次运行里的写入和回滚对得上。
    static let shared = RemoteFileChangeJournal()
    /// 每个路径保留的快照层数。
    static let maxDepth = 20

    /// 一次写入前的原文件记录。
    struct Snapshot: Sendable, Equatable {
        let id: String
        let path: String
        /// 远端快照路径。新建文件或超限跳过时为 nil。
        let snapshotPath: String?
        /// 写入前目标是否已经存在。
        let existed: Bool
        let byteCount: UInt64
        /// 超限未复制时为 false，回滚会明确失败而不是覆盖成别的版本。
        let restorable: Bool
    }

    private let sessionToken = UUID().uuidString
    private var stacks: [String: [Snapshot]] = [:]

    /// 本会话快照目录（按服务器分开）。
    func directory(serverID: UUID?) -> String {
        let scope = serverID?.uuidString ?? "local"
        return "/tmp/conchtalk-undo/\(sessionToken)/\(scope)"
    }

    /// 压入一层。超出深度时返回被挤出的最旧快照，调用方可以删掉远端文件。
    @discardableResult
    func push(_ snapshot: Snapshot, serverID: UUID?) -> Snapshot? {
        let key = storageKey(serverID: serverID, path: snapshot.path)
        var stack = stacks[key] ?? []
        stack.append(snapshot)
        var evicted: Snapshot?
        if stack.count > Self.maxDepth {
            evicted = stack.removeFirst()
        }
        stacks[key] = stack
        return evicted
    }

    /// 查看最新一层，不移除。
    func peek(serverID: UUID?, path: String) -> Snapshot? {
        stacks[storageKey(serverID: serverID, path: path)]?.last
    }

    /// 弹出最新一层。
    func pop(serverID: UUID?, path: String) -> Snapshot? {
        let key = storageKey(serverID: serverID, path: path)
        guard var stack = stacks[key], !stack.isEmpty else { return nil }
        let snapshot = stack.removeLast()
        if stack.isEmpty {
            stacks.removeValue(forKey: key)
        } else {
            stacks[key] = stack
        }
        return snapshot
    }

    private func storageKey(serverID: UUID?, path: String) -> String {
        let scope = serverID?.uuidString ?? "local"
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        return scope + "|" + trimmed
    }
}
