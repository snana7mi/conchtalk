/// 文件说明：ServerPromptOutcome，单台服务器跑完一条提示词后的结果。
import Foundation

/// ServerPromptOutcome：
/// 成功与否只描述这一台服务器。调用方不能把一台的批准套到其他服务器上。
nonisolated struct ServerPromptOutcome: Equatable, Sendable {
    var succeeded: Bool
    var assistantText: String
    var errorSummary: String?

    static func failure(_ summary: String) -> ServerPromptOutcome {
        ServerPromptOutcome(succeeded: false, assistantText: "", errorSummary: summary)
    }
}
