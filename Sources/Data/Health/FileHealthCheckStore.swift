/// 文件说明：FileHealthCheckStore，把健康检查计划存在本机 JSON 文件里。
import Foundation

/// HealthCheckStorage：健康检查计划的目录，和快捷指令无关，只在本机。
nonisolated enum HealthCheckStorage {
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("ConchTalkHealthChecks", isDirectory: true)
    }
}

/// FileHealthCheckStore：单文件保存全部计划，供调度器和设置页共用。
nonisolated final class FileHealthCheckStore: @unchecked Sendable {
    private let fileURL: URL
    private let lock = NSLock()

    init(directory: URL) {
        self.fileURL = directory.appendingPathComponent("plans.json")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func loadAll() throws -> [HealthCheckPlan] {
        lock.lock()
        defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        if data.isEmpty { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([HealthCheckPlan].self, from: data)
    }

    func save(_ plans: [HealthCheckPlan]) throws {
        lock.lock()
        defer { lock.unlock() }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(plans)
        try data.write(to: fileURL, options: .atomic)
    }
}
