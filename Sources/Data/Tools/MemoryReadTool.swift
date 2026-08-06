/// 文件说明：MemoryReadTool，提供读取核心记忆或搜索记忆条目的 AI 工具。
import Foundation

/// MemoryReadTool：
/// 统一的记忆读取工具，支持两种模式：
/// - 无 query 参数：读取当前服务器的核心记忆内容。
/// - 有 query 参数：按关键词搜索记忆条目。
/// 安全级别为 .safe（只读操作）。
nonisolated struct MemoryReadTool: ToolProtocol, @unchecked Sendable {
    let name = "memory_read"
    let description = "Read or search memory for the current server. Without query: returns core memory. With query: searches memory entries by keyword."

    private let serverID: UUID
    private let memoryReader: any MemoryReader
    private let entryStore: any MemoryEntryStore

    init(serverID: UUID, memoryReader: any MemoryReader, entryStore: any MemoryEntryStore) {
        self.serverID = serverID
        self.memoryReader = memoryReader
        self.entryStore = entryStore
    }

    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "explanation": [
                "type": "string",
                "description": "A brief explanation of why you are reading or searching memory",
            ] as [String: String],
            "query": [
                "type": "string",
                "description": "Optional search keywords. If provided, searches memory entries by matching content, tags, and entities. If omitted, returns the core memory.",
            ] as [String: String],
        ] as [String: Any],
        "required": ["explanation"],
    ]

    func validateSafety(arguments: [String: Any]) -> SafetyLevel {
        .safe
    }

    func execute(arguments: [String: Any], sshClient: SSHClientProtocol) async throws -> ToolExecutionResult {
        // 有 query 参数时走搜索模式
        if let query = arguments["query"] as? String, !query.isEmpty {
            return try await searchEntries(query: query)
        }

        // 无 query 参数时读取核心记忆
        let content = try await memoryReader.fetchMemory(forServer: serverID)
        if let content, !content.isEmpty {
            return ToolExecutionResult(output: content)
        } else {
            return ToolExecutionResult(output: "No memory found for this server.")
        }
    }

    /// 按关键词搜索记忆条目
    private func searchEntries(query: String) async throws -> ToolExecutionResult {
        let entries = try await entryStore.fetchMemoryEntries(forServer: serverID)
        let lowercasedQuery = query.lowercased()

        // 简单关键词过滤：内容、标签或实体包含查询词
        let matched = entries.filter { entry in
            entry.content.lowercased().contains(lowercasedQuery) ||
            entry.tags.contains(where: { $0.lowercased().contains(lowercasedQuery) }) ||
            entry.entities.contains(where: { $0.lowercased().contains(lowercasedQuery) })
        }

        if matched.isEmpty {
            return ToolExecutionResult(output: "No memory entries found matching: \(query)")
        }

        let resultText = matched
            .prefix(20)
            .map { entry in
                var parts = [entry.content]
                if !entry.tags.isEmpty { parts.append("Tags: \(entry.tags.joined(separator: ", "))") }
                if !entry.entities.isEmpty { parts.append("Entities: \(entry.entities.joined(separator: ", "))") }
                return parts.joined(separator: " | ")
            }
            .joined(separator: "\n")

        return ToolExecutionResult(output: "Found \(matched.count) memory entries:\n\(resultText)")
    }
}
