/// 文件说明：LiveActivityManagerTests，测试 LiveActivityManager 的核心逻辑。
import Testing
import Foundation
@testable import ConchTalk

@Suite("LiveActivityManager Tests")
struct LiveActivityManagerTests {

    @MainActor
    @Test("isAvailable 返回布尔值")
    func testIsAvailableReturnsBool() {
        let manager = LiveActivityManager()
        _ = manager.isAvailable
    }

    @MainActor
    @Test("isActive 初始为 false")
    func testIsActiveInitiallyFalse() {
        let manager = LiveActivityManager()
        #expect(!manager.isActive)
    }

    @MainActor
    @Test("endGlobalActivity 无活跃实例时无副作用")
    func testEndGlobalActivityNoOp() {
        let manager = LiveActivityManager()
        manager.endGlobalActivity()
    }

    @MainActor
    @Test("updateServers 无活跃实例时无副作用")
    func testUpdateServersNoOp() {
        let manager = LiveActivityManager()
        manager.updateServers([
            ServerSnapshot(serverID: UUID(), serverName: "test", lastReply: "", cpuUsage: 0, memoryUsage: 0, connectionSeconds: 0, hasActiveTask: false)
        ])
    }
}
