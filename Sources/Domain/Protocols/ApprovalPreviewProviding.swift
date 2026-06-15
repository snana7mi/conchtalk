/// 文件说明：ApprovalPreviewProviding，构建写操作预览的抽象契约。
import Foundation

nonisolated protocol ApprovalPreviewProviding: Sendable {
    func buildPreview(toolName: String, arguments: [String: Any], sshClient: SSHClientProtocol) async -> ApprovalPreview
}
