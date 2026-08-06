/// 文件说明：SSHCommand，定义 AI 下发的 SSH 命令载荷模型。
import Foundation

/// SSHCommand：
/// 表示一次待执行 SSH 命令，包含原始命令文本、解释说明及是否破坏性操作标记。
nonisolated struct SSHCommand: Codable, Sendable {
    let command: String
    let explanation: String
    let isDestructive: Bool

    /// CodingKeys：定义 Swift 属性与 JSON 字段的映射关系。
    enum CodingKeys: String, CodingKey {
        case command
        case explanation
        case isDestructive = "is_destructive"
    }
}
