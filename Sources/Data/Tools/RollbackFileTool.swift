/// 文件说明：RollbackFileTool，把 write_file / edit_file 改过的文件恢复到本会话快照。
import Foundation

/// RollbackFileTool：
/// 恢复最近一层会话快照。新建文件会删除；已有文件用快照原子替换。
/// 审批预览复用 ApprovalPreview 的 fileDiff，对比当前内容与快照。
nonisolated struct RollbackFileTool: ToolProtocol, @unchecked Sendable {
    let name = "rollback_file"
    let description = """
        Undo the latest write_file or edit_file change to a path in this app session. \
        Restores the snapshot taken immediately before that change. \
        Only works for changes made since the app process started.
        """

    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "path": [
                "type": "string",
                "description": "Absolute path previously changed with write_file or edit_file in this session",
            ] as [String: String],
            "explanation": [
                "type": "string",
                "description": "A brief explanation of why you are rolling back, in the user's language",
            ] as [String: String],
        ] as [String: [String: String]],
        "required": ["path", "explanation"],
    ]

    private let journal: RemoteFileChangeJournal

    init(journal: RemoteFileChangeJournal = .shared) {
        self.journal = journal
    }

    /// 回滚会改远端文件，必须确认。
    func validateSafety(arguments: [String: Any]) -> SafetyLevel {
        .needsConfirmation
    }

    /// 弹出最新快照并恢复。失败时快照仍留在栈里。
    func execute(arguments: [String: Any], sshClient: SSHClientProtocol) async throws -> ToolExecutionResult {
        guard let rawPath = arguments["path"] as? String else {
            throw ToolError.missingParameter("path")
        }
        let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let serverID = await sshClient.serverID
        guard let snapshot = await journal.peek(serverID: serverID, path: path) else {
            throw ToolError.executionFailed(
                "No session snapshot for \(path). Snapshots exist only for write_file and edit_file changes made in this app session."
            )
        }
        guard snapshot.restorable else {
            throw ToolError.executionFailed(
                "The latest change to \(path) was not snapshotted because the file was too large."
            )
        }

        if snapshot.existed {
            guard let snapshotPath = snapshot.snapshotPath else {
                throw ToolError.executionFailed("Snapshot for \(path) is missing.")
            }
            let command = AtomicRemoteWrite.restoreCommand(snapshotPath: snapshotPath, destination: path)
            _ = try await sshClient.execute(command: command, timeout: 120, reclaimOnTimeout: true)
        } else {
            _ = try await sshClient.execute(
                command: AtomicRemoteWrite.removeCommand(destination: path),
                timeout: 30,
                reclaimOnTimeout: true
            )
        }
        _ = await journal.pop(serverID: serverID, path: path)
        if let snapshotPath = snapshot.snapshotPath {
            _ = try? await sshClient.execute(
                command: "rm -f \(shellEscape(snapshotPath))",
                timeout: 15,
                reclaimOnTimeout: true
            )
        }
        return ToolExecutionResult(output: "Rolled back \(path) to session snapshot \(snapshot.id).")
    }
}
