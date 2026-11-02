/// 文件说明：CommandPolicyStore，按服务器把命令允许/拒绝列表存成本地 JSON。
import Foundation

/// CommandPolicyStore：
/// 允许/拒绝列表与「始终允许」规则分开存。规则仍走 SwiftData 的 ApprovalRule；
/// 这里只保存用户手写的词表，避免为两列字符串改数据库结构。
actor CommandPolicyStore {
    private var policies: [UUID: ServerCommandPolicy]
    private let fileURL: URL

    init(fileURL: URL? = nil) {
        let url = fileURL ?? Self.defaultFileURL
        self.fileURL = url
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        self.policies = Self.load(from: url)
    }

    func policy(for serverID: UUID) -> ServerCommandPolicy {
        policies[serverID] ?? .empty
    }

    /// 写入成功后才更新内存。空列表会删掉该服务器的条目。
    @discardableResult
    func save(_ policy: ServerCommandPolicy, for serverID: UUID) -> Bool {
        var next = policies
        if policy.allow.isEmpty && policy.deny.isEmpty {
            next.removeValue(forKey: serverID)
        } else {
            next[serverID] = policy
        }
        guard Self.persist(next, to: fileURL) else { return false }
        policies = next
        return true
    }

    private static var defaultFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base
            .appendingPathComponent("ConchTalk", isDirectory: true)
            .appendingPathComponent("command_policies.json")
    }

    nonisolated private struct Payload: Codable {
        nonisolated struct Entry: Codable {
            var serverID: UUID
            var allow: [String]
            var deny: [String]
        }
        var entries: [Entry]
    }

    private static func load(from url: URL) -> [UUID: ServerCommandPolicy] {
        guard let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            return [:]
        }
        var map: [UUID: ServerCommandPolicy] = [:]
        for entry in payload.entries {
            map[entry.serverID] = ServerCommandPolicy(allow: entry.allow, deny: entry.deny)
        }
        return map
    }

    private static func persist(_ policies: [UUID: ServerCommandPolicy], to url: URL) -> Bool {
        let entries = policies.map { serverID, policy in
            Payload.Entry(serverID: serverID, allow: policy.allow, deny: policy.deny)
        }
        do {
            let data = try JSONEncoder().encode(Payload(entries: entries))
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            print("[CommandPolicyStore] 持久化失败: \(error)")
            return false
        }
    }
}
