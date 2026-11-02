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

    @Test("普通路径为 safe，空参数也是 safe")
    func validateSafetyForOrdinaryPath() {
        #expect(sut.validateSafety(arguments: ["path": "/etc/hosts", "explanation": "test"]) == .safe)
        #expect(sut.validateSafety(arguments: [:]) == .safe)
    }

    @Test(
        "敏感路径需要确认",
        arguments: [
            "/etc/shadow",
            "/etc/gshadow",
            "/etc/master.passwd",
            "~/.ssh/id_ed25519",
            "/home/a/.ssh/id_rsa",
            "/tmp/cert.pem",
            "/tmp/server.key",
            "/app/.env",
            "/app/.env.production",
            "/home/a/.ssh/authorized_keys",
            "id_rsa",
        ]
    )
    func sensitivePathNeedsConfirmation(path: String) {
        #expect(sut.validateSafety(arguments: ["path": path, "explanation": "test"]) == .needsConfirmation)
    }

    @Test("看起来像密钥但不是的路径保持 safe", arguments: ["/etc/hosts", "/tmp/notes.txt", "/home/a/.ssh/config", "/tmp/file.keyboard"])
    func ordinaryPathStaysSafe(path: String) {
        #expect(ReadFilePolicy.isSensitivePath(path) == false)
        #expect(sut.validateSafety(arguments: ["path": path]) == .safe)
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
        #expect(mockClient.executedCommands.first?.contains("head -c") == true)
        #expect(mockClient.executedCommands.first?.contains("cat ") != true)
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

    @Test("start_line 为 0 时按第 1 行传给 sed，避免地址 0 报错")
    func startLineZeroBecomesOne() async throws {
        let mockClient = MockSSHClient()
        mockClient.executeResult = "line1"

        _ = try await sut.execute(
            arguments: ["path": "/var/log/app.log", "start_line": 0, "end_line": 5, "explanation": "test"],
            sshClient: mockClient
        )

        let command = try #require(mockClient.executedCommands.first)
        #expect(command.contains("sed -n '1,5p'"))
        #expect(!command.contains("sed -n '0,"))
    }

    @Test("end_line 小于 1 时拒绝执行")
    func endLineZeroThrows() async {
        let mockClient = MockSSHClient()
        await #expect(throws: ToolError.self) {
            _ = try await sut.execute(
                arguments: ["path": "/var/log/app.log", "end_line": 0, "explanation": "test"],
                sshClient: mockClient
            )
        }
        #expect(mockClient.executedCommands.isEmpty)
    }

    @Test("超过体积上限时不读取文件内容")
    func oversizedFileIsRefusedBeforeRead() async {
        let mockClient = MockSSHClient()
        mockClient.sftpFileSizeResult = UInt64(ReadFilePolicy.maxBytes + 1)

        await #expect(throws: ToolError.self) {
            _ = try await sut.execute(
                arguments: ["path": "/var/log/huge.log", "explanation": "test"],
                sshClient: mockClient
            )
        }
        #expect(mockClient.callCount("sftpReadFile") == 0)
        #expect(mockClient.callCount("sftpReadPrefix") == 0)
    }

    @Test("二进制前缀被拒绝，且不会再读全文")
    func binaryPrefixIsRefusedBeforeFullRead() async {
        let mockClient = MockSSHClient()
        mockClient.sftpFileSizeResult = 4
        mockClient.sftpReadResult = Data([0x00, 0x01, 0x02, 0x03])

        await #expect(throws: ToolError.self) {
            _ = try await sut.execute(
                arguments: ["path": "/tmp/a.bin", "explanation": "test"],
                sshClient: mockClient
            )
        }
        #expect(mockClient.callCount("sftpReadPrefix") == 1)
        #expect(mockClient.callCount("sftpReadFile") == 0)
    }

    @Test("显式 base64 在上限内可以读取")
    func base64UnderCap() async throws {
        let mockClient = MockSSHClient()
        let payload = Data("hi".utf8)
        mockClient.sftpFileSizeResult = UInt64(payload.count)
        mockClient.sftpReadResult = payload

        let result = try await sut.execute(
            arguments: ["path": "/tmp/a.bin", "encoding": "base64", "explanation": "test"],
            sshClient: mockClient
        )
        #expect(result.output.contains(payload.base64EncodedString()))
    }

    @Test("显式 base64 超过上限时不读取")
    func base64OverCap() async {
        let mockClient = MockSSHClient()
        mockClient.sftpFileSizeResult = UInt64(ReadFilePolicy.maxBytes + 1)
        await #expect(throws: ToolError.self) {
            _ = try await sut.execute(
                arguments: ["path": "/tmp/a.bin", "encoding": "base64", "explanation": "test"],
                sshClient: mockClient
            )
        }
        #expect(mockClient.callCount("sftpReadFile") == 0)
    }

    @Test("NUL 与非法 UTF-8 视为二进制，截断的多字节尾巴仍视为文本")
    func binaryDetection() {
        #expect(ReadFilePolicy.looksBinary(Data()) == false)
        #expect(ReadFilePolicy.looksBinary(Data("你好".utf8)) == false)
        #expect(ReadFilePolicy.looksBinary(Data([0x00, 0x41])) == true)
        #expect(ReadFilePolicy.looksBinary(Data([0xFF, 0xD8, 0xFF, 0xE0])) == true)
        var truncated = Data("hello".utf8)
        truncated.append(0xE4)
        truncated.append(0xBD)
        #expect(ReadFilePolicy.looksBinary(truncated) == false)
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
