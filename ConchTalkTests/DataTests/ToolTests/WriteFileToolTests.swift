/// 文件说明：WriteFileToolTests，测试 WriteFileTool 的安全分级与执行行为。
import Testing
@testable import ConchTalk
import Foundation

@Suite("WriteFileTool")
struct WriteFileToolTests {

    private let sut = WriteFileTool()

    // MARK: - 工具元信息

    @Test("工具名称为 write_file")
    func toolName() {
        #expect(sut.name == "write_file")
    }

    // MARK: - 安全分级

    @Test("validateSafety 返回 .needsConfirmation")
    func validateSafetyNeedsConfirmation() {
        let args: [String: Any] = ["path": "/tmp/test.txt", "content": "hello", "explanation": "test"]
        #expect(sut.validateSafety(arguments: args) == .needsConfirmation)
    }

    @Test("validateSafety 始终返回 .needsConfirmation 无论参数内容")
    func validateSafetyAlwaysNeedsConfirmation() {
        #expect(sut.validateSafety(arguments: [:]) == .needsConfirmation)
    }

    // MARK: - 正常写入

    @Test("正常写入执行至少一条 SSH 命令")
    func normalWrite() async throws {
        let mockClient = MockSSHClient()
        // executeResults: mkdir (可能), write, wc -c
        mockClient.executeResults = ["", "", "13"]

        let result = try await sut.execute(
            arguments: [
                "path": "/tmp/test.txt",
                "content": "Hello, World!",
                "explanation": "test"
            ],
            sshClient: mockClient
        )

        #expect(result.isSuccess == true)
        #expect(mockClient.executedCommands.count >= 1)
    }

    @Test("写入后输出包含成功提示或字节数")
    func writeOutputContainsSuccessInfo() async throws {
        let mockClient = MockSSHClient()
        mockClient.executeResults = ["", "", "5"]

        let result = try await sut.execute(
            arguments: [
                "path": "/tmp/hello.txt",
                "content": "hello",
                "explanation": "test"
            ],
            sshClient: mockClient
        )

        #expect(result.isSuccess == true)
        // 验证输出包含 "Written to" 或字节数信息
        let outputContainsExpected = result.output.contains("Written to") || result.output.contains("bytes") || result.output.contains("5")
        #expect(outputContainsExpected == true)
    }

    @Test("追加模式输出包含 Appended to")
    func appendModeOutput() async throws {
        let mockClient = MockSSHClient()
        mockClient.executeResults = ["", "", "15"]

        let result = try await sut.execute(
            arguments: [
                "path": "/tmp/log.txt",
                "content": "new line",
                "append": true,
                "explanation": "test"
            ],
            sshClient: mockClient
        )

        #expect(result.isSuccess == true)
        #expect(result.output.contains("Appended to") || result.output.contains("bytes"))
    }

    @Test("文本写入使用 SFTP 而非 heredoc")
    func textWriteUsesSFTP() async throws {
        let mockClient = MockSSHClient()
        mockClient.executeResults = ["", "", "5"]

        _ = try await sut.execute(
            arguments: [
                "path": "/tmp/test.txt",
                "content": "hello",
                "explanation": "test"
            ],
            sshClient: mockClient
        )

        #expect(mockClient.didCall("sftpWriteFile"))
        #expect(!mockClient.executedCommands.contains { $0.contains("cat <<") })
    }

    // MARK: - 参数缺失

    @Test("缺少 path 参数抛出 ToolError")
    func missingPathThrows() async {
        let mockClient = MockSSHClient()

        await #expect(throws: ToolError.self) {
            _ = try await sut.execute(
                arguments: ["content": "hello", "explanation": "test"],
                sshClient: mockClient
            )
        }
    }

    @Test("缺少 content 参数抛出 ToolError")
    func missingContentThrows() async {
        let mockClient = MockSSHClient()

        await #expect(throws: ToolError.self) {
            _ = try await sut.execute(
                arguments: ["path": "/tmp/test.txt", "explanation": "test"],
                sshClient: mockClient
            )
        }
    }

    @Test("base64 编码 + append=true 抛出 invalidArguments")
    func base64AppendThrowsInvalidArguments() async {
        let mockClient = MockSSHClient()

        do {
            _ = try await sut.execute(
                    arguments: [
                        "path": "/tmp/test.bin",
                        "content": "aGVsbG8=",
                        "encoding": "base64",
                        "append": true,
                        "explanation": "test"
                    ],
                    sshClient: mockClient
                )
            Issue.record("Expected ToolError.invalidArguments")
        } catch let error as ToolError {
            if case .invalidArguments(let message) = error {
                #expect(message.contains("Append mode"))
            } else {
                Issue.record("Expected invalidArguments, got \(error)")
            }
        } catch {
            Issue.record("Expected ToolError, got \(error)")
        }
    }

    @Test("无效 base64 内容抛出 invalidArguments")
    func invalidBase64ThrowsInvalidArguments() async {
        let mockClient = MockSSHClient()

        do {
            _ = try await sut.execute(
                    arguments: [
                        "path": "/tmp/test.bin",
                        "content": "%%%invalid-base64%%%",
                        "encoding": "base64",
                        "explanation": "test"
                    ],
                    sshClient: mockClient
                )
            Issue.record("Expected ToolError.invalidArguments")
        } catch let error as ToolError {
            if case .invalidArguments(let message) = error {
                #expect(message.contains("Invalid base64"))
            } else {
                Issue.record("Expected invalidArguments, got \(error)")
            }
        } catch {
            Issue.record("Expected ToolError, got \(error)")
        }
    }
}
