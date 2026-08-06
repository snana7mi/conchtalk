/// 文件说明：ConchTalkActivityAttributes，定义 Live Activity 的共享数据模型。
import Foundation
#if os(iOS)
import ActivityKit
#endif

/// ServerSnapshot：单个服务器在 Live Activity 中的快照。
struct ServerSnapshot: Codable, Hashable, Sendable {
    var serverID: UUID
    var serverName: String
    var lastReply: String
    var cpuUsage: Double
    var memoryUsage: Double
    var connectionSeconds: Int
    var hasActiveTask: Bool
}

#if os(iOS)
/// ConchTalkActivityAttributes：
/// App 与 Widget Extension 之间共享的 Live Activity 数据契约。
/// 全局单实例模型，聚合所有已连接服务器的状态。
struct ConchTalkActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var servers: [ServerSnapshot]
    }
}
#endif
