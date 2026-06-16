/// 文件说明：PushScheduleCoordinator，按 App 生命周期与审批状态预约/取消兑现推送。
import Foundation

/// PushScheduling：PushAPIClient 的 schedule/checkin 子集，便于注入测试。
nonisolated protocol PushScheduling: Sendable {
    func schedule(scheduleID: String, title: String, body: String, serverID: String, fireAfterSeconds: Int) async throws
    func checkin(scheduleID: String) async throws
    func checkinAll() async throws
}
extension PushAPIClient: PushScheduling {}

/// PushScheduleCoordinator：记录每个 serverID 在飞的 scheduleID，保证精确 check-in。
actor PushScheduleCoordinator {
    private let api: PushScheduling
    private let fireAfterSeconds: Int
    private var inFlight: [UUID: String] = [:]   // serverID → scheduleID

    init(api: PushScheduling, fireAfterSeconds: Int = 45) {
        self.api = api
        self.fireAfterSeconds = fireAfterSeconds
    }

    /// 进后台且有待审批/运行任务时调用。body 由调用方按用户语言本地化。
    func scheduleFallback(serverID: UUID, serverName: String, body: String) async {
        let scheduleID = UUID().uuidString
        inFlight[serverID] = scheduleID
        try? await api.schedule(scheduleID: scheduleID, title: serverName, body: body,
                                serverID: serverID.uuidString, fireAfterSeconds: fireAfterSeconds)
    }

    /// 回前台 / 审批已解决 / 任务结束时调用。
    func checkin(serverID: UUID) async {
        guard let scheduleID = inFlight.removeValue(forKey: serverID) else { return }
        try? await api.checkin(scheduleID: scheduleID)
    }

    /// scenePhase 回 active 兜底清理全部。
    func checkinAll() async {
        inFlight.removeAll()
        try? await api.checkinAll()
    }
}
