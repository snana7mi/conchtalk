/// 文件说明：ReadFileToolTests，测试 ReadFileTool 的安全分级与执行行为。
import Testing
@testable import ConchTalk
import Foundation

@Suite("ReadFileTool")
struct ReadFileToolTests {

    private let sut = ReadFileTool()

    // MARK: - 工具元信息

    @Test("工具名称为 read_file")
    func toolName() {
        #expect(sut.name == "read_file")
    }

    // MARK: - 安全分级

    @Test("validateSafety 始终返回 .safe")
    func validateSafetyAlwaysSafe() {
        #expect(sut.validateSafety(arguments: ["path": "/etc/hosts", "explanation": "test"]) == .safe)
        #expect(sut.validateSafety(arguments: [:]) == .safe)
    }

    // MARK: - 正常读取

    @Test("全文读取在 SFTP 失败时回退到 SSH")
    func normalRead() async throws {
        let mockClient = MockSSHClient()
        mockClient.sftpReadError = SSHError.commandFailed("sftp unavailable")
        mockClient.executeResult = "line1\nline2\n"

        let result = try await sut.execute(
            arguments: ["path": "/etc/hosts", "explanation": "test"],
            sshClient: mockClient
        )

        #expect(result.isSuccess == true)
        #expect(result.output == "line1\nline2\n")
        #expect(mockClient.executedCommands.count == 1)
        #expect(mockClient.executedCommands.first?.contains("cat") == true)
    }

    @Test("指定起始行和结束行使用 sed 命令")
    func readWithLineRange() async throws {
        let mockClient = MockSSHClient()
        mockClient.executeResult = "line3\nline4\n"

        let result = try await sut.execute(
            arguments: ["path": "/var/log/app.log", "start_line": 3, "end_line": 4, "explanation": "test"],
            sshClient: mockClient
        )

        #expect(result.isSuccess == true)
        #expect(result.output == "line3\nline4\n")
        #expect(mockClient.executedCommands.first?.contains("sed") == true)
    }

    @Test("只指定起始行使用 tail 命令")
    func readWithStartLine() async throws {
        let mockClient = MockSSHClient()
        mockClient.executeResult = "from line 10"

        let result = try await sut.execute(
            arguments: ["path": "/var/log/app.log", "start_line": 10, "explanation": "test"],
            sshClient: mockClient
        )

        #expect(result.isSuccess == true)
        #expect(result.output == "from line 10")
        #expect(mockClient.executedCommands.first?.contains("tail") == true)
    }

    @Test("只指定结束行使用 head 命令")
    func readWithEndLine() async throws {
        let mockClient = MockSSHClient()
        mockClient.executeResult = "first 5 lines"

        let result = try await sut.execute(
            arguments: ["path": "/var/log/app.log", "end_line": 5, "explanation": "test"],
            sshClient: mockClient
        )

        #expect(result.isSuccess == true)
        #expect(result.output == "first 5 lines")
        #expect(mockClient.executedCommands.first?.contains("head") == true)
    }

    // MARK: - 参数缺失

    @Test("缺少 path 参数抛出 ToolError")
    func missingPathThrows() async {
        let mockClient = MockSSHClient()

        await #expect(throws: ToolError.self) {
            _ = try await sut.execute(arguments: ["explanation": "test"], sshClient: mockClient)
        }
    }

    @Test("参数为空字典时抛出 ToolError")
    func emptyArgumentsThrows() async {
        let mockClient = MockSSHClient()

        await #expect(throws: ToolError.self) {
            _ = try await sut.execute(arguments: [:], sshClient: mockClient)
        }
    }
}
