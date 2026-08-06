/// 文件说明：ChatDerivedState，缓存展示专用的派生状态（displayMessages、messageIDsBeforeBreak 等）。
import Foundation

/// ChatDerivedState：
/// 将 displayMessages 和 messageIDsBeforeBreak 的计算提取为独立缓存，
/// 避免每次 body 重绘都重新计算。
@MainActor
struct ChatDerivedState {

    /// 过滤掉 aiContext 系统消息后的展示列表。
    let displayMessages: [Message]

    /// break 之前的消息 ID 集合（用于 UI 透明度判断），O(1) 查找。
    let messageIDsBeforeBreak: Set<UUID>

    /// 最后一条 contextBreak 消息在 messages 数组中的索引。
    let lastContextBreakIndex: Int?

    /// 从消息列表计算派生状态。
    init(messages: [Message]) {
        self.displayMessages = messages.filter {
            $0.systemMessageType != .aiContext
        }

        let breakIndex = messages.lastIndex { $0.systemMessageType == .contextBreak }
        self.lastContextBreakIndex = breakIndex

        if let breakIndex {
            self.messageIDsBeforeBreak = Set(messages.prefix(upTo: breakIndex).map(\.id))
        } else {
            self.messageIDsBeforeBreak = []
        }
    }

    /// 空状态。
    static let empty = ChatDerivedState(messages: [])
}
