/// 文件说明：ReflectService，定期整合记忆条目，去重合并并更新核心记忆。
import Foundation

/// ReflectService：
/// 负责 Reflect 阶段——定期回顾记忆条目，通过 AI 合并重复、标记过时条目，
/// 并更新核心记忆摘要。支持轻量（仅新条目）和全量（超过阈值时）两种模式。
actor ReflectService {
    private let aiService: any AIServiceProtocol
    private let entryStore: any MemoryEntryStore
    private let memoryWriter: any MemoryWriter
    private let memoryReader: any MemoryReader
    private let entryThreshold: Int

    init(
        aiService: any AIServiceProtocol,
        entryStore: any MemoryEntryStore,
        memoryWriter: any MemoryWriter,
        memoryReader: any MemoryReader,
        entryThreshold: Int = 100
    ) {
        self.aiService = aiService
        self.entryStore = entryStore
        self.memoryWriter = memoryWriter
        self.memoryReader = memoryReader
        self.entryThreshold = entryThreshold
    }

    // MARK: - Public API

    /// 轻量整合：仅处理指定时间点之后新增的条目。
    /// - Parameters:
    ///   - serverID: 关联服务器 ID。
    ///   - since: 仅处理此时间点之后创建的条目。
    func reflectRecent(serverID: UUID, since: Date) async {
        guard let allEntries = try? await entryStore.fetchMemoryEntries(forServer: serverID) else { return }
        let recentEntries = allEntries.filter { $0.createdAt > since }
        guard !recentEntries.isEmpty else { return }
        await performReflection(serverID: serverID, entries: recentEntries)
    }

    /// 全量整合：回顾所有条目，在条目数超过阈值时使用。
    /// - Parameter serverID: 关联服务器 ID。
    func reflectFull(serverID: UUID) async {
        guard let allEntries = try? await entryStore.fetchMemoryEntries(forServer: serverID),
              !allEntries.isEmpty else { return }
        await performReflection(serverID: serverID, entries: allEntries)
    }

    /// 判断是否需要执行全量整合（条目数超过阈值）。
    /// - Parameter serverID: 关联服务器 ID。
    /// - Returns: 是否应触发全量整合。
    func shouldReflectFull(serverID: UUID) async -> Bool {
        let count = (try? await entryStore.memoryEntryCount(forServer: serverID)) ?? 0
        return count >= entryThreshold
    }

    // MARK: - Private Helpers

    /// 执行反思流程：调用 AI 分析条目，删除冗余条目，可选更新核心记忆。
    private func performReflection(serverID: UUID, entries: [MemoryEntry]) async {
        let coreMemory = try? await memoryReader.fetchMemory(forServer: serverID)
        let prompt = buildPrompt(entries: entries, coreMemory: coreMemory)

        guard let responseText = try? await aiService.sendSimpleMessage(prompt) else { return }

        let (idsToDelete, updatedCoreMemory) = Self.parseReflectResponse(responseText, entries: entries)

        // 删除被标记为冗余的条目
        if !idsToDelete.isEmpty {
            try? await entryStore.deleteMemoryEntries(idsToDelete)
        }

        // 更新核心记忆（如有）
        if let updatedContent = updatedCoreMemory, !updatedContent.isEmpty {
            let memory = Memory(serverID: serverID, content: updatedContent)
            try? await memoryWriter.upsertMemory(memory)
        }
    }

    /// 构建发送给 AI 的整合提示词。
    private func buildPrompt(entries: [MemoryEntry], coreMemory: String?) -> String {
        let entriesText = entries
            .map { entry in "ID:\(entry.id.uuidString) | \(entry.content) [tags: \(entry.tags.joined(separator: ","))]" }
            .joined(separator: "\n")

        let coreMemorySection = coreMemory.map { "Current core memory:\n\($0)\n\n" } ?? ""

        return """
        \(coreMemorySection)Review the following memory entries and:
        1. Identify duplicate or outdated entries to delete
        2. Optionally update the core memory summary to reflect current state

        Return ONLY a JSON object in this exact format (no explanation, no markdown):
        {"entriesToDelete": ["uuid1", "uuid2"], "updatedCoreMemory": "...or null"}

        Memory entries:
        \(entriesText)
        """
    }

    /// 解析 AI 返回的整合结果，提取待删除 ID 列表和可选的更新核心记忆。
    static func parseReflectResponse(_ json: String, entries: [MemoryEntry]) -> ([UUID], String?) {
        let jsonString = extractJSON(from: json)
        guard let data = jsonString.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ([], nil)
        }

        // 解析待删除 ID，过滤无效 UUID
        var idsToDelete: [UUID] = []
        if let rawIDs = root["entriesToDelete"] as? [String] {
            let validIDs = Set(entries.map { $0.id.uuidString })
            for idString in rawIDs {
                if validIDs.contains(idString), let uuid = UUID(uuidString: idString) {
                    idsToDelete.append(uuid)
                }
            }
        }

        // 解析核心记忆更新
        let updatedCoreMemory: String?
        if let update = root["updatedCoreMemory"] as? String, !update.isEmpty {
            updatedCoreMemory = update
        } else {
            updatedCoreMemory = nil
        }

        return (idsToDelete, updatedCoreMemory)
    }

    /// 从可能包含额外文本的 AI 回复中提取 JSON 对象字符串。
    private static func extractJSON(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let start = trimmed.firstIndex(of: "{"),
           let end = trimmed.lastIndex(of: "}") {
            return String(trimmed[start...end])
        }
        return trimmed
    }
}
