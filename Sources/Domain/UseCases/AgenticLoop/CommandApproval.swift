/// 文件说明：CommandApproval，工具执行审批结果（四态）。
import Foundation

/// CommandApproval：用户对需确认工具调用的审批结果。
nonisolated enum CommandApproval: Equatable, Sendable {
    case denied
    case approvedOnce
    case approvedForSession
    case approvedAlways(ApprovalRule)
}
