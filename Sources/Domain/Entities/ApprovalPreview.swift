/// 文件说明：ApprovalPreview，审批卡片要展示的写操作 Diff/影响预览结果。
import Foundation

nonisolated enum ApprovalPreview: Sendable, Equatable {
    case fileDiff(lines: [DiffLine], summary: String)
    case newFile(lineCount: Int, byteCount: Int)
    case append(tailPreview: String, addedBytes: Int)
    case binaryWrite(byteCount: Int)
    case command(text: String)
    case unavailable(reason: String)
}
