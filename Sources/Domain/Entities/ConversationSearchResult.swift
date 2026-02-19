/// 文件说明：ConversationSearchResult，定义跨会话搜索结果的展示模型。
import Foundation

/// ConversationSearchResult：
/// 表示一次会话搜索命中项，包含会话与服务器信息、匹配片段及更新时间，
/// 用于搜索结果列表展示与跳转定位。
struct ConversationSearchResult: Identifiable, Sendable {
    let id: UUID
    let conversationTitle: String
    let serverName: String
    let serverID: UUID
    let matchingSnippet: String
    let updatedAt: Date
}
