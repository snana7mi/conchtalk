/// 文件说明：ContinuedProcessingKeeper，用户发起的 AI 任务在 App 退到后台后借助 BGContinuedProcessingTask（iOS 26）继续运行，并在系统 Live Activity 中显示进度。
import Foundation
import BackgroundTasks

// MARK: - 抽象（便于测试）

/// 系统 BGContinuedProcessingTask 的最小抽象。
@MainActor
protocol ContinuedProcessingTaskHandle: AnyObject {
    var progress: Progress { get }
    func updateTitle(_ title: String, subtitle: String)
    func setTaskCompleted(success: Bool)
    /// 系统（或用户在系统 UI 中点停止）使任务过期时调用；可能在任意线程触发。
    func setExpirationHandler(_ handler: (@Sendable () -> Void)?)
}

/// BGTaskScheduler 的最小抽象。
@MainActor
protocol ContinuedProcessingScheduling: AnyObject {
    var bundleIdentifier: String? { get }
    /// 注册 launch handler（在主线程回调）。返回 false 表示标识符未在 Info.plist 中声明。
    func register(
        identifier: String,
        launchHandler: @escaping @MainActor (any ContinuedProcessingTaskHandle) -> Void
    ) -> Bool
    /// 提交请求；无法立即运行时抛错（strategy = .fail）。
    func submit(identifier: String, title: String, subtitle: String) async throws
    /// 取消尚未运行的请求。
    func cancel(identifier: String)
}

// MARK: - 进度模型

/// ContinuedTaskProgressModel：
/// AI agent 循环没有确定的总步数，用「每步推进剩余量的 10%」逼近 95%，
/// 流式输出期间按心跳每 3 秒推进 1‰（上限 99%），让系统知道任务没有卡住；
/// 等待用户审批时不推进（如实反映停滞，由系统决定是否询问用户）。
nonisolated struct ContinuedTaskProgressModel: Equatable, Sendable {
    static let totalUnits: Int64 = 1000
    static let stepCeiling: Int64 = 950
    static let heartbeatCeiling: Int64 = 990
    static let heartbeatInterval: TimeInterval = 3

    private(set) var completedUnits: Int64 = 0
    private(set) var steps = 0
    private var lastChange: Date

    init(now: Date = .now) {
        lastChange = now
    }

    /// 完成一个步骤（工具调用 / 中间消息）。
    mutating func advance(now: Date = .now) {
        steps += 1
        let remaining = max(0, Self.stepCeiling - completedUnits)
        completedUnits = min(Self.heartbeatCeiling, completedUnits + max(1, remaining / 10))
        lastChange = now
    }

    /// 流式输出心跳；返回是否推进了进度。
    mutating func heartbeat(now: Date = .now) -> Bool {
        guard now.timeIntervalSince(lastChange) >= Self.heartbeatInterval,
              completedUnits < Self.heartbeatCeiling else { return false }
        completedUnits += 1
        lastChange = now
        return true
    }
}

// MARK: - Keeper

/// ContinuedProcessingKeeper：
/// - 任务在前台由用户发起时注册并提交 BGContinuedProcessingTaskRequest（`.fail` 策略：无法立即运行则放弃，
///   回退到原有的 beginBackgroundTask 短时保活）。
/// - 每个任务使用唯一标识符（`<bundle>.agentTask.<UUID>`，对应 Info.plist 通配符 `$(PRODUCT_BUNDLE_IDENTIFIER).agentTask.*`），
///   因为同一标识符重复注册会被系统直接杀掉进程。
/// - 任务结束时报告完成；系统 / 用户使任务过期时回调 `onExpired`，由编排层取消对应 AI 任务（保存部分输出）。
@MainActor
final class ContinuedProcessingKeeper {
    nonisolated static let identifierContext = "agentTask"

    private struct Entry {
        let identifier: String
        let title: String
        var subtitle: String
        var handle: (any ContinuedProcessingTaskHandle)?
        var model = ContinuedTaskProgressModel()
    }

    private let scheduler: any ContinuedProcessingScheduling
    private var entries: [UUID: Entry] = [:]

    /// 任务被系统或用户（系统 UI 中的停止按钮）终止时回调，参数为 serverID。
    var onExpired: ((UUID) -> Void)?

    init(scheduler: any ContinuedProcessingScheduling) {
        self.scheduler = scheduler
    }

    nonisolated static func identifier(bundleID: String, token: UUID = UUID()) -> String {
        "\(bundleID).\(identifierContext).\(token.uuidString)"
    }

    nonisolated static func title(serverName: String) -> String {
        String(format: String(localized: "AI task on %@", bundle: LanguageSettings.currentBundle), serverName)
    }

    nonisolated static var workingSubtitle: String {
        String(localized: "Working…", bundle: LanguageSettings.currentBundle)
    }

    nonisolated static var awaitingApprovalSubtitle: String {
        String(localized: "Waiting for your approval", bundle: LanguageSettings.currentBundle)
    }

    /// 系统 UI 副标题：取工具说明，过长截断。
    nonisolated static func subtitle(for message: Message) -> String {
        guard let toolCall = message.toolCall else { return workingSubtitle }
        let text = toolCall.explanation.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = text.isEmpty ? toolCall.toolName : text
        let singleLine = base.replacingOccurrences(of: "\n", with: " ")
        return singleLine.count > 80 ? String(singleLine.prefix(79)) + "…" : singleLine
    }

    /// 是否已为该服务器的任务申请了持续处理。
    func isTracking(serverID: UUID) -> Bool {
        entries[serverID] != nil
    }

    /// 系统是否已开始运行该任务（launch handler 已回调）。
    func isRunning(serverID: UUID) -> Bool {
        entries[serverID]?.handle != nil
    }

    /// 用户在前台发起任务时调用。返回是否已注册并发出提交。
    @discardableResult
    func begin(serverID: UUID, serverName: String) -> Bool {
        guard entries[serverID] == nil, let bundleID = scheduler.bundleIdentifier, !bundleID.isEmpty else {
            return false
        }
        let identifier = Self.identifier(bundleID: bundleID)
        let title = Self.title(serverName: serverName)
        let subtitle = Self.workingSubtitle
        let registered = scheduler.register(identifier: identifier) { [weak self] handle in
            self?.handleLaunch(serverID: serverID, identifier: identifier, handle: handle)
        }
        guard registered else {
            print("[CPK] register failed (identifier not permitted): \(identifier)")
            return false
        }
        entries[serverID] = Entry(identifier: identifier, title: title, subtitle: subtitle)
        let scheduler = self.scheduler
        Task { [weak self] in
            do {
                try await scheduler.submit(identifier: identifier, title: title, subtitle: subtitle)
            } catch {
                self?.submissionFailed(serverID: serverID, identifier: identifier, error: error)
            }
        }
        return true
    }

    /// 一个步骤完成（中间消息 / 工具结果）。
    func advance(serverID: UUID, subtitle: String? = nil) {
        guard var entry = entries[serverID] else { return }
        entry.model.advance()
        if let subtitle { entry.subtitle = subtitle }
        entries[serverID] = entry
        apply(entry, updateTitle: subtitle != nil)
    }

    /// 流式输出心跳（按间隔节流）。
    func heartbeat(serverID: UUID) {
        guard var entry = entries[serverID], entry.handle != nil else { return }
        guard entry.model.heartbeat() else { return }
        entries[serverID] = entry
        apply(entry, updateTitle: false)
    }

    /// 只更新副标题（如等待审批）。
    func setSubtitle(serverID: UUID, _ subtitle: String) {
        guard var entry = entries[serverID], entry.subtitle != subtitle else { return }
        entry.subtitle = subtitle
        entries[serverID] = entry
        apply(entry, updateTitle: true)
    }

    /// 任务结束（完成 / 取消 / 出错）。幂等。
    func finish(serverID: UUID, success: Bool = true) {
        guard let entry = entries.removeValue(forKey: serverID) else { return }
        if let handle = entry.handle {
            handle.setExpirationHandler(nil)
            handle.progress.completedUnitCount = handle.progress.totalUnitCount
            handle.setTaskCompleted(success: success)
        } else {
            // 尚未运行：撤销请求，之后若 launch handler 仍被调用会立即完成。
            scheduler.cancel(identifier: entry.identifier)
        }
    }

    // MARK: - Private

    private func handleLaunch(serverID: UUID, identifier: String, handle: any ContinuedProcessingTaskHandle) {
        guard var entry = entries[serverID], entry.identifier == identifier else {
            // AI 任务在系统启动持续处理前已结束
            handle.setTaskCompleted(success: true)
            return
        }
        handle.progress.totalUnitCount = ContinuedTaskProgressModel.totalUnits
        handle.progress.completedUnitCount = entry.model.completedUnits
        handle.setExpirationHandler { [weak self] in
            let keeper = self
            Task { @MainActor in
                keeper?.handleExpiration(serverID: serverID, identifier: identifier)
            }
        }
        entry.handle = handle
        entries[serverID] = entry
        handle.updateTitle(entry.title, subtitle: entry.subtitle)
    }

    private func handleExpiration(serverID: UUID, identifier: String) {
        guard let entry = entries[serverID], entry.identifier == identifier else { return }
        entries.removeValue(forKey: serverID)
        entry.handle?.setTaskCompleted(success: false)
        print("[CPK] continued processing expired for server \(serverID)")
        onExpired?(serverID)
    }

    private func submissionFailed(serverID: UUID, identifier: String, error: Error) {
        print("[CPK] submit failed: \(error.localizedDescription)")
        guard let entry = entries[serverID], entry.identifier == identifier, entry.handle == nil else { return }
        entries.removeValue(forKey: serverID)
    }

    private func apply(_ entry: Entry, updateTitle: Bool) {
        guard let handle = entry.handle else { return }
        handle.progress.completedUnitCount = entry.model.completedUnits
        if updateTitle {
            handle.updateTitle(entry.title, subtitle: entry.subtitle)
        }
    }
}

// MARK: - 系统实现

/// 包装 BGContinuedProcessingTask（系统对象的方法线程安全，这里仅在主线程调用）。
final class SystemContinuedProcessingTaskHandle: ContinuedProcessingTaskHandle {
    nonisolated(unsafe) private let task: BGContinuedProcessingTask

    init(task: BGContinuedProcessingTask) {
        self.task = task
    }

    var progress: Progress { task.progress }

    func updateTitle(_ title: String, subtitle: String) {
        task.updateTitle(title, subtitle: subtitle)
    }

    func setTaskCompleted(success: Bool) {
        task.setTaskCompleted(success: success)
    }

    func setExpirationHandler(_ handler: (@Sendable () -> Void)?) {
        task.expirationHandler = handler
    }
}

/// BGTaskScheduler 的系统实现。
final class SystemContinuedProcessingScheduler: ContinuedProcessingScheduling {
    var bundleIdentifier: String? { Bundle.main.bundleIdentifier }

    func register(
        identifier: String,
        launchHandler: @escaping @MainActor (any ContinuedProcessingTaskHandle) -> Void
    ) -> Bool {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { task in
            guard let continued = task as? BGContinuedProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            MainActor.assumeIsolated {
                launchHandler(SystemContinuedProcessingTaskHandle(task: continued))
            }
        }
    }

    func submit(identifier: String, title: String, subtitle: String) async throws {
        try await Self.submitRequest(identifier: identifier, title: title, subtitle: subtitle)
    }

    /// 在主线程之外提交（系统建议不要在主线程调用提交）。
    @concurrent
    private nonisolated static func submitRequest(identifier: String, title: String, subtitle: String) async throws {
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: subtitle)
        request.strategy = .fail
        if #available(iOS 27.0, *) {
            try await BGTaskScheduler.shared.submitTaskRequest(request)
        } else {
            try BGTaskScheduler.shared.submit(request)
        }
    }

    func cancel(identifier: String) {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
    }
}
