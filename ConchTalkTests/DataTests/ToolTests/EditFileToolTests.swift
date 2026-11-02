/// 文件说明：EditFileToolTests，验证编辑前快照与失败时不写文件。
import Testing
@testable import ConchTalk
import Foundation

@Suite("EditFileTool")
struct EditFileToolTests {
    @Test("唯一匹配时先 cp 快照再写入")
    func snapshotsBeforeWrite() async throws {
        let journal = RemoteFileChangeJournal()
        let sut = EditFileTool(journal: journal)
        let mock = MockSSHClient()
        mock.sftpReadResult = Data("alpha beta".utf8)
        mock.sftpFileSizeResult = 10

        let result = try await sut.execute(
            arguments: [
                "path": "/tmp/note.txt",
                "old_text": "alpha",
                "new_text": "gamma",
                "explanation": "test",
            ],
            sshClient: mock
        )

        #expect(result.output.contains("Edited /tmp/note.txt"))
        #expect(result.output.contains("rollback_file"))
        #expect(mock.executedCommands.contains { $0.contains("cp -p") })
        #expect(mock.didCall("sftpWriteFile"))
        let snapshot = await journal.peek(serverID: nil, path: "/tmp/note.txt")
        #expect(snapshot?.existed == true)
        #expect(snapshot?.restorable == true)
    }

    @Test("匹配不到时不写文件也不做快照")
    func missingTextDoesNotSnapshot() async {
        let journal = RemoteFileChangeJournal()
        let sut = EditFileTool(journal: journal)
        let mock = MockSSHClient()
        mock.sftpReadResult = Data("alpha".utf8)

        await #expect(throws: ToolError.self) {
            _ = try await sut.execute(
                arguments: [
                    "path": "/tmp/note.txt",
                    "old_text": "missing",
                    "new_text": "x",
                    "explanation": "test",
                ],
                sshClient: mock
            )
        }
        #expect(!mock.didCall("sftpWriteFile"))
        #expect(!mock.executedCommands.contains { $0.contains("cp -p") })
        let snapshot = await journal.peek(serverID: nil, path: "/tmp/note.txt")
        #expect(snapshot == nil)
    }
}
