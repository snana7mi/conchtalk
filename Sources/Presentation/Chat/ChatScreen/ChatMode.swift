/// 文件说明：ChatMode，定义聊天模式与 Agent 选择枚举。

import Foundation

/// ChatMode：聊天界面的当前交互模式，驱动视觉和消息路由。
enum ChatMode: Equatable {
    /// 正常模式：用户与 ConchTalk AI 对话。
    case normal
    /// 直连模式：用户直接与指定编码代理对话。
    case directAgent(agentName: String, agentType: AgentType)

    /// 转换为 Domain 层的 MessageSource。
    var toMessageSource: MessageSource {
        switch self {
        case .normal:
            return .normal
        case .directAgent(let agentName, _):
            return .directAgent(agentName: agentName)
        }
    }

    /// 直连模式下的代理类型；正常模式返回 nil。
    var agentType: AgentType? {
        if case .directAgent(_, let type) = self { return type }
        return nil
    }
}
