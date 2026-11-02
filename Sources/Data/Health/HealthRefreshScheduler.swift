/// 文件说明：HealthRefreshScheduler，BGAppRefreshTask 的可替换抽象和系统实现。
import Foundation
import BackgroundTasks

/// HealthRefreshTask：系统交给 App 的一次后台刷新。
@MainActor
protocol HealthRefreshTask: AnyObject {
    func setTaskCompleted(success: Bool)
    func setExpirationHandler(_ handler: (@Sendable () -> Void)?)
}

/// HealthRefreshScheduling：注册和提交 BGAppRefreshTask。测试使用假实现。
@MainActor
protocol HealthRefreshScheduling: AnyObject {
    @discardableResult
    func register(
        identifier: String,
        launchHandler: @escaping @MainActor (any HealthRefreshTask) -> Void
    ) -> Bool
    func submit(identifier: String, earliestBegin: Date) throws
    func cancel(identifier: String)
}

/// SystemHealthRefreshTask：包装 BGAppRefreshTask。
@MainActor
final class SystemHealthRefreshTask: HealthRefreshTask {
    private let task: BGAppRefreshTask

    init(task: BGAppRefreshTask) {
        self.task = task
    }

    func setTaskCompleted(success: Bool) {
        task.setTaskCompleted(success: success)
    }

    func setExpirationHandler(_ handler: (@Sendable () -> Void)?) {
        task.expirationHandler = handler
    }
}

/// SystemHealthRefreshScheduler：向系统注册固定的健康检查标识符。
@MainActor
final class SystemHealthRefreshScheduler: HealthRefreshScheduling {
    @discardableResult
    func register(
        identifier: String,
        launchHandler: @escaping @MainActor (any HealthRefreshTask) -> Void
    ) -> Bool {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { task in
            guard let refresh = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            let handle = SystemHealthRefreshTask(task: refresh)
            MainActor.assumeIsolated {
                launchHandler(handle)
            }
        }
    }

    func submit(identifier: String, earliestBegin: Date) throws {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = earliestBegin
        try BGTaskScheduler.shared.submit(request)
    }

    func cancel(identifier: String) {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
    }
}

/// HealthCheckBridge：
/// 在 App 启动时注册后台任务。容器还没建好时先记住这次唤醒，避免系统把未注册的任务杀掉进程。
@MainActor
final class HealthCheckBridge {
    static let shared = HealthCheckBridge()

    private var didRegister = false
    private var pending: (any HealthRefreshTask)?
    var handler: (@MainActor (any HealthRefreshTask) -> Void)?

    private init() {}

    static func identifier(bundleIdentifier: String?) -> String {
        let bundle = bundleIdentifier ?? "com.cheung.ConchTalk"
        return "\(bundle).healthCheck"
    }

    func registerSystem() {
        guard !didRegister else { return }
        didRegister = true
        let identifier = Self.identifier(bundleIdentifier: Bundle.main.bundleIdentifier)
        SystemHealthRefreshScheduler().register(identifier: identifier) { task in
            if let handler = HealthCheckBridge.shared.handler {
                handler(task)
            } else {
                HealthCheckBridge.shared.pending = task
            }
        }
    }

    func flushPending() {
        guard let pending, let handler else { return }
        self.pending = nil
        handler(pending)
    }
}
