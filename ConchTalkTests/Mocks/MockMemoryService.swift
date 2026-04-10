/// 文件说明：MockMemoryService，测试用记忆服务模拟，支持三协议（MemoryReader + MemoryWriter + MemoryContextProvider）。
@testable import ConchTalk
import Foundation

/// MockMemoryService：
/// 使用 actor 保证并发安全，实现 MemoryReader、MemoryWriter、MemoryContextProvider 协议的测试替身。
actor MockMemoryService: MemoryReader, MemoryWriter, MemoryContextProvider {
    /// 内存存储，key = serverID.uuidString。
    var memories: [String: String] = [:]
    /// 控制 fetchMemory 是否抛错。
    var shouldThrowOnFetch = false
    /// 控制 upsertMemory / deleteMemory 是否抛错。
    var shouldThrowOnWrite = false
    /// buildMemoryContext 返回值。
    var memoryContextResult = ""

    // MARK: - MemoryReader

    func fetchMemory(forServer serverID: UUID) async throws -> String? {
        if shouldThrowOnFetch {
            throw MockMemoryError.fetchFailed
        }
        return memories[serverID.uuidString]
    }

    // MARK: - MemoryWriter

    func upsertMemory(_ memory: Memory) async throws {
        if shouldThrowOnWrite {
            throw MockMemoryError.writeFailed
        }
        memories[memory.serverID.uuidString] = memory.content
    }

    func deleteMemory(forServer serverID: UUID) async throws {
        if shouldThrowOnWrite {
            throw MockMemoryError.writeFailed
        }
        memories.removeValue(forKey: serverID.uuidString)
    }

    // MARK: - MemoryContextProvider

    func buildMemoryContext(serverID: UUID, userInput: String) async -> String {
        memoryContextResult
    }

    // MARK: - 辅助方法

    func reset() {
        memories = [:]
        shouldThrowOnFetch = false
        shouldThrowOnWrite = false
        memoryContextResult = ""
    }
}

/// MockMemoryEntryStore：
/// 测试用记忆条目存储替身，内存中存储条目。
actor MockMemoryEntryStore: MemoryEntryStore {
    var entries: [UUID: [MemoryEntry]] = [:]

    func addMemoryEntry(_ entry: MemoryEntry) async throws {
        entries[entry.serverID, default: []].append(entry)
    }

    func fetchMemoryEntries(forServer serverID: UUID) async throws -> [MemoryEntry] {
        entries[serverID] ?? []
    }

    func deleteMemoryEntries(_ entryIDs: [UUID]) async throws {
        for key in entries.keys {
            entries[key] = entries[key]?.filter { !entryIDs.contains($0.id) }
        }
    }

    func memoryEntryCount(forServer serverID: UUID) async throws -> Int {
        entries[serverID]?.count ?? 0
    }
}

/// 测试用错误类型。
enum MockMemoryError: Error {
    case fetchFailed
    case writeFailed
}
