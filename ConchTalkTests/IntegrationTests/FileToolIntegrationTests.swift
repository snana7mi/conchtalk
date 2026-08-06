/// 文件说明：FileToolIntegrationTests，文件操作 Tool 的集成测试。
@testable import ConchTalk
import Foundation
import Testing

/// FileToolIntegrationTests：
/// 验证 ReadFileTool、WriteFileTool、EditFileTool 在真实 SSH 连接下的功能。
/// 需要设置环境变量（CT_TEST_HOST 等）才能运行，否则自动跳过。
@Suite(.tags(.integration), .serialized, .enabled(if: IntegrationTestConfig.isAvailable))
struct FileToolIntegrationTests {

    // MARK: - Helpers

    /// 生成唯一的临时文件路径，避免测试间冲突。
    private func testFilePath() -> String {
        "/tmp/conchtalk-test-\(UUID().uuidString)"
    }

    /// 通过 SSH 直接写入文件并验证文件已创建，避免依赖 WriteFileTool 的 heredoc 行为。
    private func createTestFile(content: String, at path: String, using client: SSHClientProtocol) async throws {
        let delimiter = "CONCHTALK_SETUP_\(UUID().uuidString.prefix(8))"
        let command = "cat <<'\(delimiter)' > \(path)\n\(content)\n\(delimiter)"
        _ = try await client.execute(command: command)
        // 验证文件已创建
        let check = try await client.execute(command: "test -f \(path) && echo OK || echo MISSING")
        guard check.trimmingCharacters(in: .whitespacesAndNewlines) == "OK" else {
            throw ToolError.executionFailed("Failed to create test file at \(path)")
        }
    }

    // MARK: - ReadFileTool

    /// 验证 ReadFileTool 使用 start_line/end_line 只返回指定范围的行。
    @Test
    func readFileWithLineRange() async throws {
        let config = try #require(IntegrationTestConfig.load())
        let client = try await config.connectSSH()
        defer { Task { await client.disconnect() } }

        let path = testFilePath()
        // 写入 10 行文件
        _ = try await client.execute(
            command: "printf 'line1\nline2\nline3\nline4\nline5\nline6\nline7\nline8\nline9\nline10\n' > \(path)"
        )
        defer { Task { _ = try? await client.execute(command: "rm -f \(path)") } }

        let tool = ReadFileTool()
        let result = try await tool.execute(
            arguments: [
                "path": path,
                "start_line": 3,
                "end_line": 5,
                "explanation": "test",
            ],
            sshClient: client
        )

        #expect(result.isSuccess)
        #expect(result.output.contains("line3"))
        #expect(result.output.contains("line4"))
        #expect(result.output.contains("line5"))
        // 不应包含范围外的行
        #expect(!result.output.contains("line2\n"))
        #expect(!result.output.contains("line6"))
    }

    /// 验证 ReadFileTool 读取 /etc/passwd，内容非空且包含 "root"。
    @Test
    func readFileFull() async throws {
        let config = try #require(IntegrationTestConfig.load())
        let client = try await config.connectSSH()
        defer { Task { await client.disconnect() } }

        let tool = ReadFileTool()
        let result = try await tool.execute(
            arguments: [
                "path": "/etc/passwd",
                "explanation": "test",
            ],
            sshClient: client
        )

        #expect(result.isSuccess)
        #expect(!result.output.isEmpty)
        #expect(result.output.contains("root"))
    }

    /// 验证 ReadFileTool 使用 base64 编码读取二进制文件，返回 base64 内容。
    @Test
    func readBinaryFileAsBase64() async throws {
        let config = try #require(IntegrationTestConfig.load())
        let client = try await config.connectSSH()
        defer { Task { await client.disconnect() } }

        let tool = ReadFileTool()
        let result = try await tool.execute(
            arguments: [
                "path": "/usr/bin/true",
                "encoding": "base64",
                "explanation": "test",
            ],
            sshClient: client
        )

        #expect(result.isSuccess)
        #expect(result.output.contains("Base64"))
        // base64 内容应该是可解码的非空字符串
        #expect(!result.output.isEmpty)
    }

    // MARK: - WriteFileTool

    /// 验证 WriteFileTool 创建新文件，通过 SSH cat 验证内容正确。
    @Test
    func writeFileNew() async throws {
        let config = try #require(IntegrationTestConfig.load())
        let client = try await config.connectSSH()
        defer { Task { await client.disconnect() } }

        let path = testFilePath()
        defer { Task { _ = try? await client.execute(command: "rm -f \(path)") } }

        let content = "Hello from WriteFileTool \(UUID().uuidString)"
        let tool = WriteFileTool()
        let result = try await tool.execute(
            arguments: [
                "path": path,
                "content": content,
                "explanation": "test",
            ],
            sshClient: client
        )

        #expect(result.isSuccess)

        // 通过 SSH cat 验证文件内容
        let catOutput = try await client.execute(command: "cat \(path)")
        #expect(catOutput.trimmingCharacters(in: .whitespacesAndNewlines) == content)
    }

    /// 验证 WriteFileTool 先写再追加，合并内容正确。
    @Test
    func writeFileAppend() async throws {
        let config = try #require(IntegrationTestConfig.load())
        let client = try await config.connectSSH()
        defer { Task { await client.disconnect() } }

        let path = testFilePath()
        defer { Task { _ = try? await client.execute(command: "rm -f \(path)") } }

        let tool = WriteFileTool()

        // 第一次写入
        let firstContent = "first line\n"
        _ = try await tool.execute(
            arguments: [
                "path": path,
                "content": firstContent,
                "explanation": "test",
            ],
            sshClient: client
        )

        // 追加写入
        let appendContent = "second line\n"
        let result = try await tool.execute(
            arguments: [
                "path": path,
                "content": appendContent,
                "append": true,
                "explanation": "test",
            ],
            sshClient: client
        )

        #expect(result.isSuccess)

        // 验证合并内容
        let catOutput = try await client.execute(command: "cat \(path)")
        #expect(catOutput.contains("first line"))
        #expect(catOutput.contains("second line"))
    }

    /// 验证 WriteFileTool 使用 create_backup=true 时会生成 .bak 备份文件。
    @Test
    func writeFileWithBackup() async throws {
        let config = try #require(IntegrationTestConfig.load())
        let client = try await config.connectSSH()
        defer { Task { await client.disconnect() } }

        let path = testFilePath()
        let bakPath = path + ".bak"
        defer { Task { _ = try? await client.execute(command: "rm -f \(path) \(bakPath)") } }

        let tool = WriteFileTool()

        // 先写入原始内容
        let originalContent = "original content"
        _ = try await tool.execute(
            arguments: [
                "path": path,
                "content": originalContent,
                "explanation": "test",
            ],
            sshClient: client
        )

        // 用 create_backup=true 覆盖写入
        let newContent = "new content"
        let result = try await tool.execute(
            arguments: [
                "path": path,
                "content": newContent,
                "create_backup": true,
                "explanation": "test",
            ],
            sshClient: client
        )

        #expect(result.isSuccess)

        // 验证 .bak 文件存在且包含原始内容
        let bakExists = try await client.execute(command: "test -f \(bakPath) && echo YES || echo NO")
        #expect(bakExists.trimmingCharacters(in: .whitespacesAndNewlines) == "YES")

        let bakContent = try await client.execute(command: "cat \(bakPath)")
        #expect(bakContent.contains(originalContent))
    }

    // MARK: - EditFileTool

    /// 验证 EditFileTool 精确替换文本成功。
    @Test
    func editFileReplace() async throws {
        let config = try #require(IntegrationTestConfig.load())
        let client = try await config.connectSSH()
        defer { Task { await client.disconnect() } }

        let path = testFilePath()
        defer { Task { _ = try? await client.execute(command: "rm -f \(path)") } }

        // 通过 SSH 直接写入文件，避免 WriteFileTool heredoc 的尾部换行差异
        try await createTestFile(content: "Hello World\nFoo Bar\nGoodbye", at: path, using: client)

        // 替换文本
        let editTool = EditFileTool()
        let result = try await editTool.execute(
            arguments: [
                "path": path,
                "old_text": "Foo Bar",
                "new_text": "Baz Qux",
                "explanation": "test",
            ],
            sshClient: client
        )

        #expect(result.isSuccess)

        // 验证替换结果
        let catOutput = try await client.execute(command: "cat \(path)")
        #expect(catOutput.contains("Baz Qux"))
        #expect(!catOutput.contains("Foo Bar"))
    }

    /// 验证 EditFileTool 在 old_text 不匹配时抛出错误。
    /// Python 脚本 sys.exit(1) 可能导致 SSH 层抛 SSHError.commandFailed，
    /// 也可能正常返回输出后由 EditFileTool 抛 ToolError.executionFailed，
    /// 因此这里只断言「会抛出错误」而不限定具体错误类型。
    @Test
    func editFileNoMatch() async throws {
        let config = try #require(IntegrationTestConfig.load())
        let client = try await config.connectSSH()
        defer { Task { await client.disconnect() } }

        let path = testFilePath()
        defer { Task { _ = try? await client.execute(command: "rm -f \(path)") } }

        // 通过 SSH 直接写入文件
        try await createTestFile(content: "Hello World", at: path, using: client)

        // 使用不存在的 old_text 替换——应抛出错误（ToolError 或 SSHError）
        let editTool = EditFileTool()
        await #expect(throws: (any Error).self) {
            try await editTool.execute(
                arguments: [
                    "path": path,
                    "old_text": "nonexistent text that does not appear",
                    "new_text": "replacement",
                    "explanation": "test",
                ],
                sshClient: client
            )
        }
    }

    /// 验证 EditFileTool 在 old_text 匹配多处时抛出错误。
    /// Python 脚本 sys.exit(1) 可能导致 SSH 层抛 SSHError.commandFailed，
    /// 也可能正常返回输出后由 EditFileTool 抛 ToolError.executionFailed，
    /// 因此这里只断言「会抛出错误」而不限定具体错误类型。
    @Test
    func editFileMultipleMatches() async throws {
        let config = try #require(IntegrationTestConfig.load())
        let client = try await config.connectSSH()
        defer { Task { await client.disconnect() } }

        let path = testFilePath()
        defer { Task { _ = try? await client.execute(command: "rm -f \(path)") } }

        // 通过 SSH 直接写入文件
        try await createTestFile(content: "duplicate text here\nsome middle line\nduplicate text here", at: path, using: client)

        // 尝试替换重复出现的文本——应抛出错误（ToolError 或 SSHError）
        let editTool = EditFileTool()
        await #expect(throws: (any Error).self) {
            try await editTool.execute(
                arguments: [
                    "path": path,
                    "old_text": "duplicate text here",
                    "new_text": "unique text",
                    "explanation": "test",
                ],
                sshClient: client
            )
        }
    }
}
