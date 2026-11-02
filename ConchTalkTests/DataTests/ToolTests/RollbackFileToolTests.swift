/// 文件说明：RollbackFileToolTests，验证会话快照的写入与回滚。
import Testing
@testable import ConchTalk
import Foundation

@Suite("RollbackFileTool")
struct RollbackFileToolTests {
    @Test("新建文件的回滚会删除目标")
    func rollbackNewFileRemovesIt() async throws {
        let journal = RemoteFileChangeJournal()
        let mock = MockSSHClient()
        // 快照探测时文件还不存在；写入完成后再查大小应成功。
        mock.sftpFileSizeSequence = [.failure(SSHError.commandFailed("missing"))]
        mock.sftpFileSizeResult = 5
        let path = "/tmp/brand-new.txt"

        let written = try await WriteFileTool(journal: journal).execute(
            arguments: ["path": path, "content": "hello", "explanation": "test"],
            sshClient: mock
        )
        #expect(written.output.contains("remove this new file"))
        #expect(!mock.executedCommands.contains { $0.contains("cp -p") })

        let rolled = try await RollbackFileTool(journal: journal).execute(
            arguments: ["path": path, "explanation": "test"],
            sshClient: mock
        )
        #expect(rolled.output.contains("Rolled back"))
        #expect(mock.executedCommands.contains { $0.contains("rm -f") && $0.contains(path) })
        let left = await journal.peek(serverID: nil, path: path)
        #expect(left == nil)
    }

    @Test("已有文件会 cp 快照，回滚时原子替换回来")
    func rollbackExistingFileRestoresSnapshot() async throws {
        let journal = RemoteFileChangeJournal()
        let mock = MockSSHClient()
        mock.sftpFileSizeResult = 4
        let path = "/tmp/existing.txt"

        _ = try await WriteFileTool(journal: journal).execute(
            arguments: ["path": path, "content": "next", "explanation": "test"],
            sshClient: mock
        )
        let snapshot = try #require(await journal.peek(serverID: nil, path: path))
        #expect(snapshot.existed)
        let snapshotPath = try #require(snapshot.snapshotPath)
        #expect(mock.executedCommands.contains { $0.contains("cp -p") && $0.contains(snapshotPath) })

        _ = try await RollbackFileTool(journal: journal).execute(
            arguments: ["path": path, "explanation": "test"],
            sshClient: mock
        )
        #expect(mock.executedCommands.contains { $0.contains("mv -f") && $0.contains(snapshotPath) })
    }

    @Test("没有快照时回滚失败")
    func missingSnapshotThrows() async {
        let mock = MockSSHClient()
        await #expect(throws: ToolError.self) {
            _ = try await RollbackFileTool(journal: RemoteFileChangeJournal()).execute(
                arguments: ["path": "/tmp/none.txt", "explanation": "test"],
                sshClient: mock
            )
        }
    }
}
