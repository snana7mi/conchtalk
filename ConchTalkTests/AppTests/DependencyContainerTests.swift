/// 文件说明：DependencyContainerTests，测试异步工厂的创建时间与组件完整性。
import Testing
@testable import ConchTalk
import Foundation

@Suite("DependencyContainer")
struct DependencyContainerTests {

    // MARK: - 异步创建性能

    @Test("async create() 在合理时间内完成")
    @MainActor
    func createCompletesQuickly() async {
        let start = CFAbsoluteTimeGetCurrent()
        let container = await DependencyContainer.create()
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        // 应在 3 秒内完成（包含 ModelContainer 创建）
        // CI 环境可能更慢，给予宽松上限
        #expect(elapsed < 3.0, "DependencyContainer.create() took \(String(format: "%.2f", elapsed))s, expected < 3s")

        // 验证核心组件已就绪
        _ = container.modelContainer
        _ = container.store
        _ = container.sshManager
        _ = container.aiService
        _ = container.toolRegistry
        _ = container.skillRegistry
        _ = container.taskExecutionCoordinator
    }

    @Test("async create() 不阻塞主线程")
    @MainActor
    func createDoesNotBlockMainThread() async {
        // 在 create() 执行期间，主线程应能处理其他任务
        var mainThreadTaskRan = false

        async let container = DependencyContainer.create()

        // 如果 create() 阻塞主线程，这个 Task 不会被执行
        // 使用 Task 来检测主线程是否可调度
        await Task { @MainActor in
            mainThreadTaskRan = true
        }.value

        let _ = await container
        #expect(mainThreadTaskRan, "Main thread was blocked during DependencyContainer.create()")
    }

    // MARK: - ViewModel 工厂

    @Test("makeChatViewModel 同一服务器复用缓存实例")
    @MainActor
    func chatViewModelReusesCachedInstance() async {
        let container = await DependencyContainer.create()
        let server = TestFixtures.makeServer()

        let vm1 = container.makeChatViewModel(for: server)
        let vm2 = container.makeChatViewModel(for: server)

        // 同一 server 复用已有实例，保持直连模式等会话状态
        #expect(vm1 === vm2)
    }

    @Test("removeChatViewModel 清除缓存后重新创建实例")
    @MainActor
    func chatViewModelCreatesNewInstanceAfterRemoval() async {
        let container = await DependencyContainer.create()
        let server = TestFixtures.makeServer()

        let vm1 = container.makeChatViewModel(for: server)
        container.removeChatViewModel(for: server.id)
        let vm2 = container.makeChatViewModel(for: server)

        #expect(vm1 !== vm2)
    }

    // MARK: - 新架构组合图

    @Test("DependencyContainer 正确构建 TaskExecutionCoordinator 组合图")
    @MainActor
    func dependencyContainer_buildsTEC() async {
        let container = await DependencyContainer.create()

        let tec = container.taskExecutionCoordinator

        // 验证 TEC 的各子组件已就绪
        _ = tec.taskQueue
        _ = tec.stateStore
        _ = tec.lifecycleManager
        _ = tec.keepAlive

        // 验证初始状态正确
        #expect(tec.activeTaskServerIDs.isEmpty)
        #expect(tec.isAppInForeground == true)
    }

    @Test("ChatViewModel 通过 makeChatViewModel 获得已连线的 TaskExecutionCoordinator")
    @MainActor
    func chatViewModel_hasWiredTaskCoordinator() async {
        let container = await DependencyContainer.create()
        let server = TestFixtures.makeServer()

        let vm = container.makeChatViewModel(for: server)

        // 验证 ChatViewModel 持有的 taskCoordinator 与 container 中一致
        #expect(vm.taskCoordinator === container.taskExecutionCoordinator)
    }
}
