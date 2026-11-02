/// 文件说明：ApprovalPreviewBuilder，按工具类型构建写操作的 Diff/影响预览（只读、尽力而为、有界）。
import Foundation

/// ApprovalPreviewBuilder：
/// - edit_file：直接 diff(old_text, new_text)，不读远端。
/// - write_file 文本覆盖：读远端 vs content 出 diff；读不到 → newFile；append/base64 各自分支。
/// - rollback_file：当前内容 diff 到会话快照（复用 fileDiff）。
/// - execute_ssh_command：command（仅回显命令，无 dry-run）。
/// 任何读失败/超限 → unavailable，绝不抛错、绝不执行。
struct ApprovalPreviewBuilder: ApprovalPreviewProviding {
    /// diff 读文件大小上限（字节）。
    private let maxBytes = 256 * 1024
    /// 与 write/edit 共用的会话快照栈。
    private let journal: RemoteFileChangeJournal

    init(journal: RemoteFileChangeJournal = .shared) {
        self.journal = journal
    }

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

        case "rollback_file":
            return await rollbackPreview(arguments: arguments, sshClient: sshClient)

        default:
            return .unavailable(reason: "no preview")
        }
    }

    /// 回滚预览：把当前文件 diff 成快照内容。新建文件的回滚表现为整文件删除。
    private func rollbackPreview(arguments: [String: Any], sshClient: SSHClientProtocol) async -> ApprovalPreview {
        guard let rawPath = arguments["path"] as? String else {
            return .unavailable(reason: "missing arguments")
        }
        let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let serverID = await sshClient.serverID
        guard let snapshot = await journal.peek(serverID: serverID, path: path) else {
            return .unavailable(reason: "no session snapshot")
        }
        guard snapshot.restorable else {
            return .unavailable(reason: "snapshot was skipped because the file was too large")
        }
        if !snapshot.existed {
            guard let data = try? await sshClient.sftpReadFile(path: path),
                  data.count <= maxBytes,
                  let text = String(data: data, encoding: .utf8) else {
                return .unavailable(reason: "rollback will delete \(path)")
            }
            return diffPreview(old: text, new: "")
        }
        guard let snapshotPath = snapshot.snapshotPath else {
            return .unavailable(reason: "snapshot is missing")
        }
        if let size = try? await sshClient.sftpFileSize(path: path), size > UInt64(maxBytes) {
            return .unavailable(reason: "file too large to diff (\(size) bytes)")
        }
        if let size = try? await sshClient.sftpFileSize(path: snapshotPath), size > UInt64(maxBytes) {
            return .unavailable(reason: "snapshot too large to diff (\(size) bytes)")
        }
        guard let currentData = try? await sshClient.sftpReadFile(path: path),
              let current = String(data: currentData, encoding: .utf8),
              let snapData = try? await sshClient.sftpReadFile(path: snapshotPath),
              let previous = String(data: snapData, encoding: .utf8) else {
            return .unavailable(reason: "unable to read snapshot")
        }
        return diffPreview(old: current, new: previous)
    }

    /// 把两段文本收成 fileDiff。old 是现在的内容，new 是回滚后的内容。
    private func diffPreview(old: String, new: String) -> ApprovalPreview {
        let lines = LineDiff.diff(
            old: old.components(separatedBy: "\n"),
            new: new.components(separatedBy: "\n")
        )
        let added = lines.filter { if case .added = $0 { true } else { false } }.count
        let removed = lines.filter { if case .removed = $0 { true } else { false } }.count
        return .fileDiff(lines: lines, summary: "+\(added) −\(removed)")
    }
}
