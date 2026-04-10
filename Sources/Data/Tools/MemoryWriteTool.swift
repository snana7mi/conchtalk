/// 文件说明：MemoryWriteTool，提供更新核心记忆或添加记忆条目的 AI 工具。
import Foundation

/// MemoryWriteTool：
/// 统一的记忆写入工具，支持两种模式：
/// - type: "core" + content：更新核心记忆（需用户确认）。
/// - type: "entry" + content + 可选 tags/entities：添加记忆条目（自动执行）。
nonisolated struct MemoryWriteTool: ToolProtocol, @unchecked Sendable {
    let name = "memory_write"
    let description = "Write to memory for the current server. Use type 'core' to update the core memory (replaces existing), or type 'entry' to add a specific fact/observation as a memory entry."

    private let serverID: UUID
    private let memoryWriter: any MemoryWriter
    private let entryStore: any MemoryEntryStore

    init(serverID: UUID, memoryWriter: any MemoryWriter, entryStore: any MemoryEntryStore) {
        self.serverID = serverID
        self.memoryWriter = memoryWriter
        self.entryStore = entryStore
    }

    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "type": [
                "type": "string",
                "enum": ["core", "entry"],
                "description": "The type of memory to write. 'core' updates the server's core memory (replaces existing). 'entry' adds a new fact/observation as a memory entry.",
            ] as [String: Any],
            "content": [
                "type": "string",
                "description": "The content to write. For 'core': the full core memory text. For 'entry': a self-contained fact or observation.",
            ] as [String: String],
            "tags": [
                "type": "array",
                "items": ["type": "string"],
                "description": "Category tags for a memory entry (only used when type is 'entry', e.g. ['nginx', 'web', 'config']).",
            ] as [String: Any],
            "entities": [
                "type": "array",
                "items": ["type": "string"],
                "description": "Named entities mentioned in a memory entry (only used when type is 'entry', e.g. service names, file paths, usernames).",
            ] as [String: Any],
            "explanation": [
                "type": "string",
                "description": "A brief explanation of what you are storing and why",
            ] as [String: String],
        ] as [String: Any],
        "required": ["type", "content", "explanation"],
    ]

    func validateSafety(arguments: [String: Any]) -> SafetyLevel {
        let type = arguments["type"] as? String
        // 核心记忆更新需要用户确认，条目添加为安全操作
        if type == "core" {
            return .needsConfirmation
        }
        return .safe
    }

    func execute(arguments: [String: Any], sshClient: SSHClientProtocol) async throws -> ToolExecutionResult {
        guard let type = arguments["type"] as? String else {
            throw ToolError.missingParameter("type")
        }
        guard let content = arguments["content"] as? String, !content.isEmpty else {
            throw ToolError.missingParameter("content")
        }

        switch type {
        case "core":
            return try await updateCoreMemory(content: content)
        case "entry":
            return try await addEntry(content: content, arguments: arguments)
        default:
            throw ToolError.invalidArguments("type must be 'core' or 'entry'")
        }
    }

    /// 更新核心记忆
    private func updateCoreMemory(content: String) async throws -> ToolExecutionResult {
        let memory = Memory(serverID: serverID, content: content)
        try await memoryWriter.upsertMemory(memory)
        return ToolExecutionResult(output: "Core memory updated successfully.")
    }

    /// 添加记忆条目
    private func addEntry(content: String, arguments: [String: Any]) async throws -> ToolExecutionResult {
        let tags = arguments["tags"] as? [String] ?? []
        let entities = arguments["entities"] as? [String] ?? []

        let entry = MemoryEntry(
            serverID: serverID,
            content: content,
            tags: tags,
            entities: entities,
            source: "ai_tool"
        )

        try await entryStore.addMemoryEntry(entry)
        return ToolExecutionResult(output: "Memory entry added successfully.")
    }
}
