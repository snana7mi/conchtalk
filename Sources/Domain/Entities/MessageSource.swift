/// 文件说明：MessageSource，标记消息的来源模式。

import Foundation

/// MessageSource：消息产生时的来源标识。
/// 用于区分消息来自 ConchTalk AI 还是直连编码代理，
/// 以便 AI 回到 normal 模式后能感知直连期间的对话内容。
nonisolated enum MessageSource: Codable, Sendable, Equatable {
    /// 正常模式：ConchTalk AI 对话。
    case normal
    /// 直连模式：用户直接与指定编码代理对话。
    case directAgent(agentName: String)
}
