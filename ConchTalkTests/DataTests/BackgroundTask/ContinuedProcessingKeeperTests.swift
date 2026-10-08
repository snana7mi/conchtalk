/// 文件说明：ContinuedProcessingKeeperTests，验证 BGContinuedProcessingTask 持续处理的注册、提交、进度、完成与过期回调。
import Testing
@testable import ConchTalk
import Foundation

@MainActor
final class FakeContinuedTaskHandle: ContinuedProcessingTaskHandle {
    let progress = Progress(totalUnitCount: 0)
    private(set) var titles: [(String, String)] = []
    private(set) var completed: Bool?
    private(set) var expirationHandler: (@Sendable () -> Void)?

    func updateTitle(_ title: String, subtitle: String) { titles.append((title, subtitle)) }
    func setTaskCompleted(success: Bool) { completed = success }
    func setExpirationHandler(_ handler: (@Sendable () -> Void)?) { expirationHandler = handler }
}

@MainActor
final class FakeContinuedScheduler: ContinuedProcessingScheduling {
    var bundleIdentifier: String? = "com.cheung.ConchTalk"
    var allowRegister = true
    var submitError: Error?
    private(set) var registered: [String: @MainActor (any ContinuedProcessingTaskHandle) -> Void] = [:]
    private(set) var submitted: [(identifier: String, title: String, subtitle: String)] = []
    private(set) var cancelled: [String] = []

    func register(identifier: String, launchHandler: @escaping @MainActor (any ContinuedProcessingTaskHandle) -> Void) -> Bool {
        guard allowRegister else { return false }
        #expect(registered[identifier] == nil, "同一标识符不得重复注册")
        registered[identifier] = launchHandler
        return true
    }

    func submit(identifier: String, title: String, subtitle: String) async throws {
        submitted.append((identifier, title, subtitle))
        if let submitError { throw submitError }
    }

    func cancel(identifier: String) { cancelled.append(identifier) }

    /// 模拟系统启动任务。
    func launch(_ identifier: String, handle: FakeContinuedTaskHandle) {
        registered[identifier]?(handle)
    }
}

@Suite("ContinuedProcessingKeeper")
@MainActor
struct ContinuedProcessingKeeperTests {

    private func settle() async {
        for _ in 0..<5 { await Task.yield() }
    }

    @Test("标识符匹配 Info.plist 通配符且每次唯一")
    func identifierFormat() {
        let a = ContinuedProcessingKeeper.identifier(bundleID: "com.cheung.ConchTalk")
        let b = ContinuedProcessingKeeper.identifier(bundleID: "com.cheung.ConchTalk")
        #expect(a.hasPrefix("com.cheung.ConchTalk.agentTask."))
        #expect(a != b)
    }

    @Test("Info.plist 声明了持续处理通配符标识符")
    func infoPlistDeclaresIdentifier() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Info.plist")
        let plist = try #require(NSDictionary(contentsOf: url))
        let ids = try #require(plist["BGTaskSchedulerPermittedIdentifiers"] as? [String])
        #expect(ids.contains("$(PRODUCT_BUNDLE_IDENTIFIER).\(ContinuedProcessingKeeper.identifierContext).*"))
    }

    @Test("begin 注册并提交；launch 后设置进度、标题与过期处理；finish 报告成功")
    func fullLifecycle() async throws {
        let scheduler = FakeContinuedScheduler()
        let keeper = ContinuedProcessingKeeper(scheduler: scheduler)
        let server = UUID()

        #expect(keeper.begin(serverID: server, serverName: "prod"))
        #expect(!keeper.begin(serverID: server, serverName: "prod"), "同一服务器任务只申请一次")
        await settle()
        let request = try #require(scheduler.submitted.first)
        #expect(request.title.contains("prod"))
        #expect(!keeper.isRunning(serverID: server))

        let handle = FakeContinuedTaskHandle()
        scheduler.launch(request.identifier, handle: handle)
        #expect(keeper.isRunning(serverID: server))
        #expect(handle.progress.totalUnitCount == ContinuedTaskProgressModel.totalUnits)
        #expect(handle.expirationHandler != nil)
        #expect(handle.titles.last?.0 == request.title)

        keeper.advance(serverID: server, subtitle: "List files")
        #expect(handle.progress.completedUnitCount > 0)
        #expect(handle.titles.last?.1 == "List files")

        keeper.finish(serverID: server)
        #expect(handle.completed == true)
        #expect(handle.progress.completedUnitCount == handle.progress.totalUnitCount)
        #expect(!keeper.isTracking(serverID: server))
        keeper.finish(serverID: server) // 幂等
    }

    @Test("任务在系统启动前结束：撤销请求，迟到的 launch 立即完成")
    func finishBeforeLaunch() async throws {
        let scheduler = FakeContinuedScheduler()
        let keeper = ContinuedProcessingKeeper(scheduler: scheduler)
        let server = UUID()
        keeper.begin(serverID: server, serverName: "dev")
        await settle()
        let id = try #require(scheduler.submitted.first?.identifier)
        keeper.finish(serverID: server)
        #expect(scheduler.cancelled == [id])

        let late = FakeContinuedTaskHandle()
        scheduler.launch(id, handle: late)
        #expect(late.completed == true)
    }

    @Test("提交失败（无法立即运行 / 模拟器不支持）时回退并允许下次重新申请")
    func submitFailure() async {
        let scheduler = FakeContinuedScheduler()
        scheduler.submitError = NSError(domain: "BGTaskSchedulerErrorDomain", code: 4)
        let keeper = ContinuedProcessingKeeper(scheduler: scheduler)
        let server = UUID()
        #expect(keeper.begin(serverID: server, serverName: "dev"))
        await settle()
        #expect(!keeper.isTracking(serverID: server))
        #expect(keeper.begin(serverID: server, serverName: "dev"))
    }

    @Test("未声明标识符或缺少 bundle ID 时不申请")
    func registrationGuards() {
        let scheduler = FakeContinuedScheduler()
        scheduler.allowRegister = false
        let keeper = ContinuedProcessingKeeper(scheduler: scheduler)
        #expect(!keeper.begin(serverID: UUID(), serverName: "x"))
        scheduler.allowRegister = true
        scheduler.bundleIdentifier = nil
        #expect(!keeper.begin(serverID: UUID(), serverName: "x"))
    }

    @Test("过期（系统 UI 停止）回调 onExpired 并报告失败")
    func expiration() async throws {
        let scheduler = FakeContinuedScheduler()
        let keeper = ContinuedProcessingKeeper(scheduler: scheduler)
        let server = UUID()
        let expired = LockedBox<[UUID]>([])
        keeper.onExpired = { id in expired.withValue { $0.append(id) } }
        keeper.begin(serverID: server, serverName: "prod")
        await settle()
        let handle = FakeContinuedTaskHandle()
        scheduler.launch(try #require(scheduler.submitted.first?.identifier), handle: handle)

        let expire = try #require(handle.expirationHandler)
        expire()
        for _ in 0..<50 where expired.value.isEmpty {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(expired.value == [server])
        #expect(handle.completed == false)
        #expect(!keeper.isTracking(serverID: server))
    }

    @Test("等待审批时只更新副标题，不推进进度")
    func approvalSubtitle() async throws {
        let scheduler = FakeContinuedScheduler()
        let keeper = ContinuedProcessingKeeper(scheduler: scheduler)
        let server = UUID()
        keeper.begin(serverID: server, serverName: "prod")
        await settle()
        let handle = FakeContinuedTaskHandle()
        scheduler.launch(try #require(scheduler.submitted.first?.identifier), handle: handle)
        let before = handle.progress.completedUnitCount
        keeper.setSubtitle(serverID: server, ContinuedProcessingKeeper.awaitingApprovalSubtitle)
        #expect(handle.progress.completedUnitCount == before)
        #expect(handle.titles.last?.1 == ContinuedProcessingKeeper.awaitingApprovalSubtitle)
    }

    @Test("进度模型：步骤逼近 95%，心跳节流且不超过 99%")
    func progressModel() {
        let start = Date(timeIntervalSince1970: 0)
        var model = ContinuedTaskProgressModel(now: start)
        for i in 1...200 { model.advance(now: start.addingTimeInterval(Double(i))) }
        #expect(model.completedUnits <= ContinuedTaskProgressModel.heartbeatCeiling)
        #expect(model.completedUnits >= 940)

        var fresh = ContinuedTaskProgressModel(now: start)
        let tooSoon = fresh.heartbeat(now: start.addingTimeInterval(1))
        let due = fresh.heartbeat(now: start.addingTimeInterval(3))
        let units = fresh.completedUnits
        let throttled = fresh.heartbeat(now: start.addingTimeInterval(4))
        #expect(!tooSoon)
        #expect(due)
        #expect(units == 1)
        #expect(!throttled)
    }

    @Test("副标题：工具说明优先，过长截断，非工具消息显示处理中")
    func subtitles() {
        let tool = ToolCall(id: "1", toolName: "execute_ssh_command", argumentsJSON: Data("{}".utf8), explanation: String(repeating: "a", count: 120))
        let sub = ContinuedProcessingKeeper.subtitle(for: Message(role: .assistant, content: "", toolCall: tool))
        #expect(sub.count == 80)
        #expect(sub.hasSuffix("…"))
        let bare = ToolCall(id: "2", toolName: "read_file", argumentsJSON: Data("{}".utf8), explanation: "")
        #expect(ContinuedProcessingKeeper.subtitle(for: Message(role: .assistant, content: "", toolCall: bare)) == "read_file")
        #expect(ContinuedProcessingKeeper.subtitle(for: Message(role: .assistant, content: "hi")) == ContinuedProcessingKeeper.workingSubtitle)
    }
}
