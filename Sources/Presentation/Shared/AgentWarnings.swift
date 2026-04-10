/// 文件说明：AgentWarnings，Agent 类型相关的警告信息集中管理。

import Foundation

/// AgentWarnings：
/// 集中管理各 Agent 类型的警告信息。
/// 新增警告只需在 `warnings(for:)` 中添加条目，UI 层统一消费。
enum AgentWarnings {

    /// 返回指定 agent 类型的所有警告信息，无警告时返回空数组。
    static func warnings(for type: AgentType) -> [String] {
        switch type {
        case .openclaw:
            return [
                String(localized: "The handshake connection with OpenClaw is currently unstable and may fail during the process.", bundle: LanguageSettings.currentBundle),
            ]
        case .gemini:
            return [
                String(localized: "Using Gemini 3.0/3.1 Pro models may cause message failures. It is recommended to use other models.", bundle: LanguageSettings.currentBundle),
            ]
        default:
            return []
        }
    }

    /// 将警告数组合并为单条显示文本，空数组返回 nil。
    static func combinedMessage(for type: AgentType) -> String? {
        let msgs = warnings(for: type)
        guard !msgs.isEmpty else { return nil }
        return msgs.joined(separator: "\n")
    }
}
