/// 文件说明：ChatViewModelLifecycleTests，验证 ChatViewModel 的释放路径与事件消费任务生命周期。
import Testing
@testable import ConchTalk
import Foundation
@preconcurrency import ACPModel

@Suite("ChatViewModel Lifecycle")
@MainActor
struct ChatViewModelLifecycleTests {

    @Test("外部强引用清空后 ChatViewModel 可被释放")
    func chatViewModel_deallocates_afterReleasingStrongReference() async throws {
        let store = try ChatViewModelTestSupport.makeInMemoryStore()
        let server = TestFixtures.makeServer()
        try await store.saveServer(server)

        var viewModel: ChatViewModel? = ChatViewModelTestSupport.makeViewModel(server: server, store: store)
        weak var weakVM = viewModel

        // 先让 directEventTask 的消费循环真正启动并挂起在 for-await 上
        // （不让出主线程的话任务体尚未运行，测不到引用环）
        for _ in 0..<5 { await Task.yield() }

        viewModel = nil

        // 给 isolated deinit 与级联释放留几拍
        var released = false
        for _ in 0..<50 {
            await Task.yield()
            if weakVM == nil {
                released = true
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(released, "ChatViewModel 应在外部强引用清空后释放（引用环已断开）")
    }

    @Test("disconnectAndCleanup 取消并清空 directEventTask")
    func disconnectAndCleanup_cancelsDirectEventTask() async throws {
        let store = try ChatViewModelTestSupport.makeInMemoryStore()
        let server = TestFixtures.makeServer()
        try await store.saveServer(server)

        let viewModel = ChatViewModelTestSupport.makeViewModel(server: server, store: store)
        await viewModel.loadMessages()
        #expect(viewModel.directEventTask != nil)

        await viewModel.disconnectAndCleanup()

        #expect(viewModel.directEventTask == nil)
    }

    @Test("VM 存活期间事件消费循环正常投递事件")
    func eventConsumption_stillDeliversEvents_whileVMAlive() async throws {
        let store = try ChatViewModelTestSupport.makeInMemoryStore()
        let server = TestFixtures.makeServer()
        try await store.saveServer(server)

        let viewModel = ChatViewModelTestSupport.makeViewModel(server: server, store: store)

        // 换上可控的 coordinator 并重启消费循环（消费的是任务启动时捕获的流）
        let factory: DirectSessionCoordinator.SessionFactory = makeCoordinatorSessionFactory(
            [.success(displayName: "Codex")],
            probes: SessionProbePool()
        )
        let coordinator = DirectSessionCoordinator(sessionFactory: factory)
        viewModel.directSessionCoordinator = coordinator
        viewModel.directEventTask?.cancel()
        viewModel.startDirectSessionEventConsumption()

        let agent = AgentInfo(type: .codex, path: "/usr/bin/codex", version: nil)
        await coordinator.connect(agent: agent, cwd: "/tmp/work")

        // sendPrompt 同步发出 .messageReady(用户消息) 事件，经消费循环落入 messages
        coordinator.sendPrompt("hello from direct")

        var delivered = false
        for _ in 0..<100 {
            if viewModel.messages.contains(where: { $0.role == .user && $0.content == "hello from direct" }) {
                delivered = true
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(delivered, "弱引用消费循环应继续投递事件")
    }
}
