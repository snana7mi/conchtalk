/// 文件说明：MemoryServiceProtocol，定义记忆系统的读写与上下文组装接口。
import Foundation

/// MemoryReader：记忆读取协议，提供只读访问。
/// - `nil` 表示无数据，`throw` 表示读取失败。
protocol MemoryReader: Sendable {
    /// 读取指定服务器的记忆内容。
    func fetchMemory(forServer serverID: UUID) async throws -> String?
}

/// MemoryWriter：记忆写入协议，提供写入和删除能力。
protocol MemoryWriter: Sendable {
    /// 写入或更新指定服务器的记忆。
    func upsertMemory(_ memory: Memory) async throws
    /// 删除指定服务器的记忆。目标不存在时静默成功（幂等）。
    func deleteMemory(forServer serverID: UUID) async throws
}

/// MemoryEntryStore：细粒度记忆条目存取协议。
protocol MemoryEntryStore: Sendable {
    /// 添加单条记忆条目。
    func addMemoryEntry(_ entry: MemoryEntry) async throws
    /// 读取指定服务器的所有记忆条目。
    func fetchMemoryEntries(forServer serverID: UUID) async throws -> [MemoryEntry]
    /// 删除指定记忆条目。
    func deleteMemoryEntries(_ entryIDs: [UUID]) async throws
    /// 返回指定服务器的记忆条目数量。
    func memoryEntryCount(forServer serverID: UUID) async throws -> Int
}

/// MemoryContextProvider：记忆上下文组装协议，提供格式化的记忆注入文本。
protocol MemoryContextProvider: Sendable {
    /// 根据服务器 ID 组装可注入系统提示词的记忆上下文文本。
    func buildMemoryContext(serverID: UUID, userInput: String) async -> String
}
