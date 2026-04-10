/// 文件说明：AgentConnectionResult，用户在连接确认弹窗中的选择结果。
import Foundation

/// AgentConnectionResult：
/// 当 AI 建议连接编码代理时，用户通过弹窗确认后的结果。
nonisolated enum AgentConnectionResult: Sendable {
    /// 用户确认接入，UI 进入直接模式。cwd 为用户选择的工作目录。
    case confirmed(cwd: String?)
    /// 用户取消了接入。
    case cancelled
    /// 服务器无可用 agent 或不支持 ACP 协议。
    case unsupported
    /// 用户选择自定义路径，AI 应在对话中询问。
    case customPath
}
