/// 文件说明：PollBackgroundCommandToolTests，验证后台日志轮询的路径限制与命令。
import Testing
@testable import ConchTalk
import Foundation

@Suite("PollBackgroundCommandTool")
struct PollBackgroundCommandToolTests {
    private let sut = PollBackgroundCommandTool()

    @Test("只读托管日志为 safe")
    func managedLogIsSafe() {
        #expect(sut.validateSafety(arguments: ["log_path": "/tmp/conchtalk-bg/job.log"]) == .safe)
    }

    @Test("拒绝托管目录以外的路径")
    func rejectsUnmanagedPath() async {
        let mock = MockSSHClient()
        await #expect(throws: ToolError.self) {
            _ = try await sut.execute(
                arguments: ["log_path": "/etc/passwd", "explanation": "test"],
                sshClient: mock
            )
        }
        #expect(mock.executedCommands.isEmpty)
    }

    @Test("拒绝带 .. 的日志路径")
    func rejectsDotDot() async {
        let mock = MockSSHClient()
        await #expect(throws: ToolError.self) {
            _ = try await sut.execute(
                arguments: ["log_path": "/tmp/conchtalk-bg/../shadow", "explanation": "test"],
                sshClient: mock
            )
        }
        #expect(mock.executedCommands.isEmpty)
    }

    @Test("轮询命令只 tail 托管日志，并限制行数")
    func pollsManagedLog() async throws {
        let mock = MockSSHClient()
        mock.executeResult = "status=running\n---\nhello"

        let result = try await sut.execute(
            arguments: [
                "log_path": "/tmp/conchtalk-bg/job.log",
                "pid": "42",
                "tail_lines": 9_999,
                "explanation": "test",
            ],
            sshClient: mock
        )

        #expect(result.output.contains("status=running"))
        let command = try #require(mock.executedCommands.first)
        #expect(command.contains("tail -n 200"))
        #expect(command.contains("kill -0 42"))
        #expect(command.contains(shellEscape("/tmp/conchtalk-bg/job.log")))
        #expect(mock.callHistory.last?.arguments["reclaimOnTimeout"] == "true")
    }

    @Test("pid 必须是数字")
    func rejectsNonNumericPid() async {
        let mock = MockSSHClient()
        await #expect(throws: ToolError.self) {
            _ = try await sut.execute(
                arguments: ["log_path": "/tmp/conchtalk-bg/job.log", "pid": "42;rm", "explanation": "test"],
                sshClient: mock
            )
        }
    }
}
