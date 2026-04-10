/// 文件说明：FileToolTests，测试文件操作工具（EditFile、ReadFile、WriteFile、UploadFile）的安全分级和基础执行行为。
import Testing
@testable import ConchTalk
import Foundation

// MARK: - EditFileTool

@Suite("EditFileTool")
struct EditFileToolTests {

    private let sut = EditFileTool()

    @Test("工具名称为 edit_file")
    func toolName() {
        #expect(sut.name == "edit_file")
    }

    @Test("validateSafety 返回 .needsConfirmation")
    func validateSafety() {
        let args: [String: Any] = [
            "path": "/tmp/test.txt",
            "old_text": "foo",
            "new_text": "bar",
            "explanation": "test"
        ]
        #expect(sut.validateSafety(arguments: args) == .needsConfirmation)
    }

    @Test("缺少 path 参数抛出 ToolError")
    func missingPathThrows() async {
        let mockClient = MockSSHClient()

        await #expect(throws: ToolError.self) {
            _ = try await sut.execute(
                arguments: ["old_text": "foo", "new_text": "bar", "explanation": "test"],
                sshClient: mockClient
            )
        }
    }

    @Test("缺少 old_text 参数抛出 ToolError")
    func missingOldTextThrows() async {
        let mockClient = MockSSHClient()

        await #expect(throws: ToolError.self) {
            _ = try await sut.execute(
                arguments: ["path": "/tmp/test.txt", "new_text": "bar", "explanation": "test"],
                sshClient: mockClient
            )
        }
    }

    @Test("缺少 new_text 参数抛出 ToolError")
    func missingNewTextThrows() async {
        let mockClient = MockSSHClient()

        await #expect(throws: ToolError.self) {
            _ = try await sut.execute(
                arguments: ["path": "/tmp/test.txt", "old_text": "foo", "explanation": "test"],
                sshClient: mockClient
            )
        }
    }

    @Test("执行时优先通过 SFTP 读写文件")
    func executeUsesSFTP() async throws {
        let mockClient = MockSSHClient()
        mockClient.sftpReadResult = Data("hello".utf8)

        let result = try await sut.execute(
            arguments: [
                "path": "/tmp/test.txt",
                "old_text": "hello",
                "new_text": "world",
                "explanation": "test"
            ],
            sshClient: mockClient
        )

        #expect(result.isSuccess == true)
        #expect(mockClient.didCall("sftpReadFile"))
        #expect(mockClient.didCall("sftpWriteFile"))
    }
}

// MARK: - ReadFileTool (SFTP/base64 功能，原 SFTPReadFileTool)

@Suite("ReadFileTool — SFTP/base64 mode")
struct ReadFileToolSFTPTests {

    private let sut = ReadFileTool()

    @Test("全文读取优先走 SFTP 返回内容")
    func readTextFileSFTP() async throws {
        let mockClient = MockSSHClient()
        let content = "Hello, World!\n"
        mockClient.sftpReadResult = content.data(using: .utf8)!

        let result = try await sut.execute(
            arguments: ["path": "/tmp/test.txt", "explanation": "test"],
            sshClient: mockClient
        )

        #expect(result.isSuccess == true)
        #expect(result.output.contains("Hello, World!"))
        #expect(mockClient.didCall("sftpReadFile"))
    }

    @Test("base64 编码模式返回 base64 内容")
    func readBase64Mode() async throws {
        let mockClient = MockSSHClient()
        mockClient.sftpReadResult = Data([0x89, 0x50, 0x4E, 0x47]) // PNG header

        let result = try await sut.execute(
            arguments: ["path": "/tmp/image.png", "encoding": "base64", "explanation": "test"],
            sshClient: mockClient
        )

        #expect(result.isSuccess == true)
        #expect(result.output.contains("Base64"))
    }
}

// MARK: - WriteFileTool (SFTP/base64 功能，原 SFTPWriteFileTool)

@Suite("WriteFileTool — SFTP/base64 mode")
struct WriteFileToolSFTPTests {

    private let sut = WriteFileTool()

    @Test("base64 编码模式写入解码后的数据")
    func writeBase64Content() async throws {
        let mockClient = MockSSHClient()
        let base64Content = "aGVsbG8=" // "hello" in base64
        mockClient.sftpFileSizeResult = 5

        let result = try await sut.execute(
            arguments: [
                "path": "/tmp/test.bin",
                "content": base64Content,
                "encoding": "base64",
                "explanation": "test"
            ],
            sshClient: mockClient
        )

        #expect(result.isSuccess == true)
        #expect(mockClient.didCall("sftpWriteFile"))
    }
}

// MARK: - UploadFileTool

@Suite("UploadFileTool")
struct UploadFileToolTests {

    private let sut = UploadFileTool()

    @Test("工具名称为 upload_file")
    func toolName() {
        #expect(sut.name == "upload_file")
    }

    @Test("validateSafety 返回 .needsConfirmation")
    func validateSafety() {
        let args: [String: Any] = ["filename": "report.pdf", "remote_path": "/home/user/report.pdf"]
        #expect(sut.validateSafety(arguments: args) == .needsConfirmation)
    }

    @Test("supportsStreaming 为 true")
    func supportsStreaming() {
        #expect(sut.supportsStreaming == true)
    }

    @Test("无附件时返回 isSuccess=false 的错误提示")
    func noAttachmentsReturnsError() async throws {
        let mockClient = MockSSHClient()

        // 不提供 _attachments，会触发 invalidArguments 错误
        await #expect(throws: ToolError.self) {
            _ = try await sut.execute(
                arguments: [
                    "filename": "report.pdf",
                    "remote_path": "/home/user/report.pdf"
                ],
                sshClient: mockClient
            )
        }
    }

    @Test("附件中无匹配文件名时返回 isSuccess=false")
    func noMatchingAttachmentReturnsError() async throws {
        let mockClient = MockSSHClient()
        let attachment = FileAttachment(fileName: "other.txt", fileSize: 5, mimeType: "text/plain", data: Data("hello".utf8))

        let result = try await sut.execute(
            arguments: [
                "filename": "report.pdf",
                "remote_path": "/home/user/report.pdf",
                "_attachments": [attachment]
            ],
            sshClient: mockClient
        )

        #expect(result.isSuccess == false)
        #expect(result.output.contains("not found") || result.output.contains("Error"))
    }
}
