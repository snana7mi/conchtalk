/// 文件说明：RetainService，任务完成后从对话中提取事实并写入记忆条目。
import Foundation

/// FactExtraction：
/// 单条从对话中提取的事实，包含内容、标签与实体。
struct FactExtraction: Sendable {
    let content: String
    let tags: [String]
    let entities: [String]
}

/// RetainResult：
/// AI 提取结果，包含事实列表与可选的核心记忆更新建议。
struct RetainResult: Sendable {
    let facts: [FactExtraction]
    let coreMemoryUpdate: String?
}

/// RetainService：
/// 负责 Retain 阶段——在任务完成后调用 AI 从对话中提取 2-5 条结构化事实，
/// 并将其写入 MemoryEntryStore，同时可选地更新核心记忆。
actor RetainService {
    private let aiService: any AIServiceProtocol
    private let memoryWriter: any MemoryWriter
    private let entryStore: any MemoryEntryStore

    init(
        aiService: any AIServiceProtocol,
        memoryWriter: any MemoryWriter,
        entryStore: any MemoryEntryStore
    ) {
        self.aiService = aiService
        self.memoryWriter = memoryWriter
        self.entryStore = entryStore
    }

    // MARK: - Public API

    /// 从对话消息中提取事实并持久化到记忆存储。
    /// - Parameters:
    ///   - serverID: 关联服务器 ID。
    ///   - recentMessages: 最近的对话消息列表。
    func retain(serverID: UUID, recentMessages: [Message]) async {
        guard !recentMessages.isEmpty else { return }

        let prompt = buildPrompt(recentMessages: recentMessages)
        guard let responseText = try? await aiService.sendSimpleMessage(prompt) else { return }

        let result = Self.parseRetainResponse(responseText)

        // 写入提取到的事实条目
        for fact in result.facts {
            let entry = MemoryEntry(
                serverID: serverID,
                content: fact.content,
                tags: fact.tags,
                entities: fact.entities,
                source: "conversation"
            )
            try? await entryStore.addMemoryEntry(entry)
        }

        // 更新核心记忆（如有）
        if let updatedContent = result.coreMemoryUpdate, !updatedContent.isEmpty {
            let memory = Memory(serverID: serverID, content: updatedContent)
            try? await memoryWriter.upsertMemory(memory)
        }
    }

    // MARK: - Parsing

    /// 解析 AI 返回的 JSON，提取 facts 数组与 coreMemoryUpdate。
    /// - Parameter json: AI 返回的 JSON 字符串（可能含前缀文本）。
    /// - Returns: 解析后的 RetainResult；解析失败时返回空结果。
    static func parseRetainResponse(_ json: String) -> RetainResult {
        // 尝试提取 JSON 块（兼容 AI 在 JSON 前后添加说明文字的情况）
        let jsonString = extractJSON(from: json)
        guard let data = jsonString.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return RetainResult(facts: [], coreMemoryUpdate: nil)
        }

        var facts: [FactExtraction] = []
        if let factsArray = root["facts"] as? [[String: Any]] {
            for item in factsArray {
                guard let content = item["content"] as? String, !content.isEmpty else { continue }
                let tags = item["tags"] as? [String] ?? []
                let entities = item["entities"] as? [String] ?? []
                facts.append(FactExtraction(content: content, tags: tags, entities: entities))
            }
        }

        // coreMemoryUpdate 为 null 或缺失时返回 nil
        let coreMemoryUpdate: String?
        if let update = root["coreMemoryUpdate"] as? String, !update.isEmpty {
            coreMemoryUpdate = update
        } else {
            coreMemoryUpdate = nil
        }

        return RetainResult(facts: facts, coreMemoryUpdate: coreMemoryUpdate)
    }

    // MARK: - Private Helpers

    /// 构建向 AI 发送的提取提示词。
    private func buildPrompt(recentMessages: [Message]) -> String {
        let conversationText = recentMessages
            .filter { $0.role == .user || $0.role == .assistant }
            .map { "[\($0.role.rawValue)]: \($0.content)" }
            .joined(separator: "\n")

        return """
        Extract 2-5 self-contained, factual observations from the following conversation that would be useful to remember for future sessions with this server. Focus on: server configuration, services running, paths, user preferences, and resolved issues.

        Return ONLY a JSON object in this exact format (no explanation, no markdown):
        {"facts": [{"content": "...", "tags": ["tag1"], "entities": ["entity1"]}], "coreMemoryUpdate": "...or null"}

        Conversation:
        \(conversationText)
        """
    }

    /// 从可能包含额外文本的 AI 回复中提取 JSON 对象字符串。
    private static func extractJSON(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // 找到第一个 '{' 到最后一个 '}'
        if let start = trimmed.firstIndex(of: "{"),
           let end = trimmed.lastIndex(of: "}") {
            return String(trimmed[start...end])
        }
        return trimmed
    }
}
