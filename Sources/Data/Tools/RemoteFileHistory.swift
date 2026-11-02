/// 文件说明：RemoteFileHistory，在 write/edit 改文件之前把原文件复制到会话快照。
import Foundation

/// RemoteFileHistory：
/// 文件已存在且不超过上限时，在远端 `cp -p` 保留模式与属主。
/// 文件不存在时只记一条「回滚即删除」的记录。复制失败则中止写入。
nonisolated enum RemoteFileHistory {
    /// 单次快照复制上限。再大的文件仍允许写入，但这次变更不能回滚。
    static let maxSnapshotBytes: UInt64 = 32 * 1024 * 1024

    /// 写入前记录原文件。返回值要附在工具结果里，方便模型调用 rollback_file。
    static func capture(
        path rawPath: String,
        sshClient: SSHClientProtocol,
        journal: RemoteFileChangeJournal
    ) async throws -> RemoteFileChangeJournal.Snapshot {
        let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let serverID = await sshClient.serverID
        let id = UUID().uuidString
        let snapshot: RemoteFileChangeJournal.Snapshot
        if let size = try? await sshClient.sftpFileSize(path: path) {
            if size > maxSnapshotBytes {
                snapshot = RemoteFileChangeJournal.Snapshot(
                    id: id, path: path, snapshotPath: nil, existed: true, byteCount: size, restorable: false
                )
            } else {
                let directory = await journal.directory(serverID: serverID)
                let snapshotPath = directory + "/" + id
                let command = "mkdir -p \(shellEscape(directory)) && cp -p \(shellEscape(path)) \(shellEscape(snapshotPath))"
                do {
                    _ = try await sshClient.execute(command: command, timeout: 120, reclaimOnTimeout: true)
                } catch {
                    throw ToolError.executionFailed(
                        "Failed to snapshot \(path) before writing: \(error.localizedDescription)"
                    )
                }
                snapshot = RemoteFileChangeJournal.Snapshot(
                    id: id, path: path, snapshotPath: snapshotPath, existed: true, byteCount: size, restorable: true
                )
            }
        } else {
            snapshot = RemoteFileChangeJournal.Snapshot(
                id: id, path: path, snapshotPath: nil, existed: false, byteCount: 0, restorable: true
            )
        }

        if let evicted = await journal.push(snapshot, serverID: serverID), let oldPath = evicted.snapshotPath {
            _ = try? await sshClient.execute(
                command: "rm -f \(shellEscape(oldPath))",
                timeout: 15,
                reclaimOnTimeout: true
            )
        }
        return snapshot
    }

    /// 附在写入成功结果后的一句说明。
    static func note(for snapshot: RemoteFileChangeJournal.Snapshot) -> String {
        if !snapshot.restorable {
            return " Snapshot skipped because the file is larger than \(maxSnapshotBytes) bytes; rollback_file cannot restore this change."
        }
        if snapshot.existed {
            return " Session snapshot \(snapshot.id) saved; rollback_file can restore this file."
        }
        return " Session snapshot \(snapshot.id) saved; rollback_file will remove this new file."
    }
}
