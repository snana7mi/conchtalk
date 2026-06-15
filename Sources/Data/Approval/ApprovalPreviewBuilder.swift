/// 文件说明：ApprovalPreviewBuilder，按工具类型构建写操作的 Diff/影响预览（只读、尽力而为、有界）。
import Foundation

/// ApprovalPreviewBuilder：
/// - edit_file：直接 diff(old_text, new_text)，不读远端。
/// - write_file 文本覆盖：读远端 vs content 出 diff；读不到 → newFile；append/base64 各自分支。
/// - execute_ssh_command：command（仅回显命令，无 dry-run）。
/// 任何读失败/超限 → unavailable，绝不抛错、绝不执行。
struct ApprovalPreviewBuilder: ApprovalPreviewProviding {
    /// diff 读文件大小上限（字节）。
    private let maxBytes = 256 * 1024

    func buildPreview(toolName: String, arguments: [String: Any], sshClient: SSHClientProtocol) async -> ApprovalPreview {
        switch toolName {
        case "execute_ssh_command":
            let cmd = (arguments["command"] as? String) ?? ""
            return .command(text: cmd)

        case "edit_file":
            let oldText = (arguments["old_text"] as? String) ?? ""
            let newText = (arguments["new_text"] as? String) ?? ""
            let lines = LineDiff.diff(old: oldText.components(separatedBy: "\n"),
                                      new: newText.components(separatedBy: "\n"))
            let added = lines.filter { if case .added = $0 { true } else { false } }.count
            let removed = lines.filter { if case .removed = $0 { true } else { false } }.count
            return .fileDiff(lines: lines, summary: "+\(added) −\(removed)")

        case "write_file":
            guard let path = arguments["path"] as? String,
                  let content = arguments["content"] as? String else {
                return .unavailable(reason: "missing arguments")
            }
            let encoding = (arguments["encoding"] as? String) ?? "text"
            let append = (arguments["append"] as? Bool) ?? false
            if encoding == "base64" {
                let bytes = Data(base64Encoded: content)?.count ?? content.count
                return .binaryWrite(byteCount: bytes)
            }
            if append {
                let tail = content.components(separatedBy: "\n").prefix(20).joined(separator: "\n")
                return .append(tailPreview: tail, addedBytes: content.utf8.count)
            }
            // 文本覆盖：先看大小，再读
            if let size = try? await sshClient.sftpFileSize(path: path), size > UInt64(maxBytes) {
                return .unavailable(reason: "file too large to diff (\(size) bytes)")
            }
            guard let data = try? await sshClient.sftpReadFile(path: path),
                  let remote = String(data: data, encoding: .utf8) else {
                // 读不到：当作新建文件
                return .newFile(lineCount: content.components(separatedBy: "\n").count, byteCount: content.utf8.count)
            }
            let lines = LineDiff.diff(old: remote.components(separatedBy: "\n"),
                                      new: content.components(separatedBy: "\n"))
            let added = lines.filter { if case .added = $0 { true } else { false } }.count
            let removed = lines.filter { if case .removed = $0 { true } else { false } }.count
            return .fileDiff(lines: lines, summary: "+\(added) −\(removed)")

        default:
            return .unavailable(reason: "no preview")
        }
    }
}
