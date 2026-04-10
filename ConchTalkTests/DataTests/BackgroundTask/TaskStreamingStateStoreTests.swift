/// 文件说明：TaskStreamingStateStoreTests，验证流式状态管理与 observer 通知。
import Testing
@testable import ConchTalk
import Foundation

@Suite("TaskStreamingStateStore")
@MainActor
struct TaskStreamingStateStoreTests {

    @Test("初始化和获取状态")
    func initAndGet() {
        let store = TaskStreamingStateStore()
        let id = UUID()

        store.initState(for: id)
        let state = store.state(for: id)
        #expect(state != nil)
        #expect(state?.isStreaming == false)
    }

    @Test("使用自定义初始状态")
    func initWithCustomState() {
        let store = TaskStreamingStateStore()
        let id = UUID()

        store.initState(for: id, state: TaskStreamingState(isStreaming: true))
        #expect(store.state(for: id)?.isStreaming == true)
    }

    @Test("获取不存在的状态返回 nil")
    func getNonexistentState() {
        let store = TaskStreamingStateStore()
        #expect(store.state(for: UUID()) == nil)
    }

    @Test("更新状态")
    func updateState() {
        let store = TaskStreamingStateStore()
        let id = UUID()
        store.initState(for: id)

        store.updateState(for: id) { $0.activeContentText = "hello" }

        #expect(store.state(for: id)?.activeContentText == "hello")
    }

    @Test("更新不存在的状态无副作用")
    func updateNonexistentState() {
        let store = TaskStreamingStateStore()
        store.updateState(for: UUID()) { $0.activeContentText = "hello" }
        // 不崩溃即通过
    }

    @Test("observer 注册后通过 notifyObserver 收到更新")
    func observerReceivesUpdate() {
        let store = TaskStreamingStateStore()
        let id = UUID()
        store.initState(for: id)

        var received: TaskStreamingState?
        store.setObserver(for: id) { state in
            received = state
        }

        store.updateState(for: id) { $0.isStreaming = true }
        store.notifyObserver(for: id)

        #expect(received?.isStreaming == true)
    }

    @Test("setObserver emitCurrent 立即推送当前状态")
    func setObserverEmitCurrent() {
        let store = TaskStreamingStateStore()
        let id = UUID()
        store.initState(for: id, state: TaskStreamingState(activeContentText: "existing"))

        var received: TaskStreamingState?
        store.setObserver(for: id, emitCurrent: true) { state in
            received = state
        }

        #expect(received?.activeContentText == "existing")
    }

    @Test("observer 注销后不收到更新")
    func unregisteredNoUpdate() {
        let store = TaskStreamingStateStore()
        let id = UUID()
        store.initState(for: id)

        var callCount = 0
        store.setObserver(for: id) { _ in callCount += 1 }
        store.setObserver(for: id, callback: nil)

        store.updateState(for: id) { $0.isStreaming = true }
        store.notifyObserver(for: id)

        #expect(callCount == 0)
    }

    @Test("清理状态")
    func removeState() {
        let store = TaskStreamingStateStore()
        let id = UUID()
        store.initState(for: id)
        store.updateState(for: id) { $0.activeContentText = "test" }

        store.removeState(for: id)

        #expect(store.state(for: id) == nil)
    }

    @Test("removeState 同时清除 observer")
    func removeStateRemovesObserver() {
        let store = TaskStreamingStateStore()
        let id = UUID()
        store.initState(for: id)
        store.setObserver(for: id) { _ in }

        #expect(store.hasObserver(for: id))
        store.removeState(for: id)
        #expect(!store.hasObserver(for: id))
    }

    @Test("hasObserver 正确反映")
    func hasObserver() {
        let store = TaskStreamingStateStore()
        let id = UUID()
        store.initState(for: id)

        #expect(!store.hasObserver(for: id))
        store.setObserver(for: id) { _ in }
        #expect(store.hasObserver(for: id))
    }

    @Test("observer 获取引用")
    func getObserverReference() {
        let store = TaskStreamingStateStore()
        let id = UUID()
        store.initState(for: id)

        #expect(store.observer(for: id) == nil)
        store.setObserver(for: id) { _ in }
        #expect(store.observer(for: id) != nil)
    }

    @Test("scheduleNotify 合并推送")
    func scheduleNotifyCoalesced() async throws {
        let store = TaskStreamingStateStore()
        let id = UUID()
        store.initState(for: id)

        var callCount = 0
        store.setObserver(for: id) { _ in callCount += 1 }

        // 多次 scheduleNotify 应被合并为一次
        store.scheduleNotify(for: id)
        store.scheduleNotify(for: id)
        store.scheduleNotify(for: id)

        // 等待 coalesced 推送（16ms + 余量）
        try await Task.sleep(for: .milliseconds(50))

        #expect(callCount == 1)
    }

    @Test("多个会话独立管理")
    func multipleConversations() {
        let store = TaskStreamingStateStore()
        let id1 = UUID()
        let id2 = UUID()

        store.initState(for: id1)
        store.initState(for: id2)

        store.updateState(for: id1) { $0.activeContentText = "conv1" }
        store.updateState(for: id2) { $0.activeContentText = "conv2" }

        #expect(store.state(for: id1)?.activeContentText == "conv1")
        #expect(store.state(for: id2)?.activeContentText == "conv2")

        store.removeState(for: id1)
        #expect(store.state(for: id1) == nil)
        #expect(store.state(for: id2)?.activeContentText == "conv2")
    }
}
