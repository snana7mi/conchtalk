/// 文件说明：WebSearchProvider，定义联网搜索支持的服务提供商。
import Foundation

/// WebSearchProvider：
/// 表示用户可选的搜索服务；原始值用于本地持久化与 Keychain 条目标识。
nonisolated enum WebSearchProvider: String, CaseIterable, Codable, Hashable, Sendable {
    case brave
    case exa
    case anySearch = "anysearch"
    case tavily

    /// 固定品牌名无需本地化。
    var displayName: String {
        switch self {
        case .brave: "Brave"
        case .exa: "Exa"
        case .anySearch: "AnySearch"
        case .tavily: "Tavily"
        }
    }
}
