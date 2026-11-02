/// 文件说明：Runbook，用户从成功对话保存下来的可复用操作手册。
import Foundation

/// Runbook：
/// 一份可再次执行的任务模板。它同时是一条用户数据，以及一份符合 Skill 格式的策略文本。
nonisolated struct Runbook: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    /// Skill 名称（小写字母、数字、连字符）。
    var name: String
    /// 用户可见名称。
    var displayName: String
    /// 供模型判断何时使用的英文描述。
    var description: String
    /// 再次执行时发给模型的过程正文（不含外层引导语）。
    var prompt: String
    /// 完整 SKILL.md 文本，激活后注入对话。
    var skillMarkdown: String
    var createdAt: Date
    var modifiedAt: Date
    var isDeleted: Bool
    /// 保存时所在的服务器；再次运行可以换一台。
    var sourceServerID: UUID?

    init(
        id: UUID = UUID(),
        name: String,
        displayName: String,
        description: String,
        prompt: String,
        skillMarkdown: String,
        createdAt: Date = Date(),
        modifiedAt: Date = Date(),
        isDeleted: Bool = false,
        sourceServerID: UUID? = nil
    ) {
        self.id = id
        self.name = name
        self.displayName = displayName
        self.description = description
        self.prompt = prompt
        self.skillMarkdown = skillMarkdown
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.isDeleted = isDeleted
        self.sourceServerID = sourceServerID
    }
}

/// RunbookDraft：从对话抽出、尚未落盘的手册内容。
nonisolated struct RunbookDraft: Equatable, Sendable {
    var suggestedDisplayName: String
    var prompt: String
}

/// RunbookExtractionFailure：对话还不能保存为手册的原因。
nonisolated enum RunbookExtractionFailure: Equatable, Sendable, Error {
    /// 当前上下文里没有用户请求。
    case noUserRequest
    /// 助手还没有成功结束这一轮。
    case notSuccessful
}

/// RunbookSaveFailure：生成可保存手册失败的原因。
nonisolated enum RunbookSaveFailure: Equatable, Sendable, Error {
    case emptyName
    case extraction(RunbookExtractionFailure)
}
