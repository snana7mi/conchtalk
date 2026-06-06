/// 文件说明：CommandApproval，工具执行审批结果。
import Foundation

/// CommandApproval：用户对高危工具调用的审批结果。
nonisolated enum CommandApproval: Equatable, Sendable {
    case approved
    case denied
}
