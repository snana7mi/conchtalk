/// 文件说明：ConfirmationRequest，安全门交给审批 UI 的请求（工具调用 + 预览 + 建议规则）。
import Foundation

nonisolated struct ConfirmationRequest: Sendable {
    let toolCall: ToolCall
    let preview: ApprovalPreview?
    let suggestedRule: ApprovalRule?
    let canRemember: Bool
}
