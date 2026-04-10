/// 文件说明：BackgroundDisconnectionPlan，定义后台断线时的重连与清理策略。
import Foundation

/// BackgroundDisconnectionPlan：后台恢复时的断线处理计划。
struct BackgroundDisconnectionPlan: Equatable {
    /// 当前聊天页所属服务器，优先原地自动重连。
    let reconnectInPlaceServerID: UUID?
    /// 其余只需清理的断线服务器。
    let cleanupServerIDs: [UUID]

    init(disconnectedServerIDs: [UUID], currentChatServerID: UUID?) {
        let uniqueServerIDs = Array(NSOrderedSet(array: disconnectedServerIDs)) as? [UUID] ?? disconnectedServerIDs

        if let currentChatServerID, uniqueServerIDs.contains(currentChatServerID) {
            reconnectInPlaceServerID = currentChatServerID
            cleanupServerIDs = uniqueServerIDs.filter { $0 != currentChatServerID }
        } else {
            reconnectInPlaceServerID = nil
            cleanupServerIDs = uniqueServerIDs
        }
    }
}
