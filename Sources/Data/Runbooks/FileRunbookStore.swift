/// 文件说明：FileRunbookStore，把操作手册以 JSON 存在 Application Support，并做软删除。
import Foundation

/// RunbookStorage：操作手册文件的固定目录，App 与 App Intent 共用。
nonisolated enum RunbookStorage {
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("ConchTalkRunbooks", isDirectory: true)
    }
}

/// RunbookStoring：手册的读取、保存与软删除。
nonisolated protocol RunbookStoring: Sendable {
    func loadAll() throws -> [Runbook]
    func save(_ runbook: Runbook) throws
    func softDelete(id: UUID, now: Date) throws
    func purgeDeleted(olderThan interval: TimeInterval, now: Date) throws
}

/// FileRunbookStore：
/// 单文件 JSON。删除只打墓碑，物理清理由 `purgeDeleted` 按保留期执行。
nonisolated final class FileRunbookStore: RunbookStoring, @unchecked Sendable {
    private let fileURL: URL
    private let lock = NSLock()
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(directory: URL) {
        self.fileURL = directory.appendingPathComponent("runbooks.json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func loadAll() throws -> [Runbook] {
        lock.lock()
        defer { lock.unlock() }
        return try loadUnlocked().filter { !$0.isDeleted }
            .sorted { $0.modifiedAt > $1.modifiedAt }
    }

    func save(_ runbook: Runbook) throws {
        lock.lock()
        defer { lock.unlock() }
        var all = try loadUnlocked()
        if let index = all.firstIndex(where: { $0.id == runbook.id }) {
            var updated = runbook
            updated.createdAt = all[index].createdAt
            all[index] = updated
        } else {
            all.append(runbook)
        }
        try writeUnlocked(all)
    }

    func softDelete(id: UUID, now: Date) throws {
        lock.lock()
        defer { lock.unlock() }
        var all = try loadUnlocked()
        guard let index = all.firstIndex(where: { $0.id == id }) else { return }
        all[index].isDeleted = true
        all[index].modifiedAt = now
        try writeUnlocked(all)
    }

    func purgeDeleted(olderThan interval: TimeInterval, now: Date) throws {
        lock.lock()
        defer { lock.unlock() }
        let all = try loadUnlocked()
        let kept = all.filter { record in
            guard record.isDeleted else { return true }
            return now.timeIntervalSince(record.modifiedAt) < interval
        }
        if kept.count != all.count {
            try writeUnlocked(kept)
        }
    }

    private func loadUnlocked() throws -> [Runbook] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        if data.isEmpty { return [] }
        return try decoder.decode([Runbook].self, from: data)
    }

    private func writeUnlocked(_ runbooks: [Runbook]) throws {
        let data = try encoder.encode(runbooks)
        try data.write(to: fileURL, options: .atomic)
    }
}
