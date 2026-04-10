/// 文件说明：DirectSessionState，直连模式 session 协调器的状态快照与 token 类型。
import Foundation
@preconcurrency import ACPModel

/// DirectSessionToken：唯一标识一次 session 连接，防止跨 session 竞态。
struct DirectSessionToken: Equatable, Sendable {
    fileprivate(set) var rawValue: UInt64
}

/// DirectSessionState：
/// 捕获 DirectSessionCoordinator 管理的核心状态，
/// 不包含 UI 特有的标志（如滚动触发器、configSheet 显示等）。
struct DirectSessionState {
    /// 当前生命周期阶段。
    var lifecycle: DirectModeLifecycle = .idle
    /// 当前连接的 agent 身份信息。
    var activeAgent: DirectModePresentationState.AgentIdentity?
    /// session 元数据（命令、模型、模式、配置项）。
    var metadata: DirectModeMetadata = DirectModeMetadata()
    /// 当前 session token（防止跨 session 竞态）。
    var currentSessionToken: DirectSessionToken?
    /// agent 工作目录。
    var cwd: String?
    /// 累积的流式事件。
    var accumulatedEvents: [AgentStreamEvent] = []
    /// 直连模式开始时的消息计数（用于上下文摘要提取）。
    var directModeStartMessageCount: Int = 0
}
