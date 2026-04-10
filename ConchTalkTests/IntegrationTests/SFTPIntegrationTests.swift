/// 文件说明：SFTPIntegrationTests，SFTP 文件操作的集成测试。
@testable import ConchTalk
import Foundation
import Testing

/// SFTPIntegrationTests：
/// 验证 NIOSSHClient 的 SFTP 读写文件和文件大小查询功能。
/// 需要设置环境变量（CT_TEST_HOST 等）才能运行，否则自动跳过。
@Suite(.tags(.integration), .serialized)
struct SFTPIntegrationTests {

    // MARK: - Helpers

    /// 生成唯一的临时文件路径，避免测试间冲突。
    private func testFilePath() -> String {
        "/tmp/conchtalk-test-\(UUID().uuidString)"
    }

    // MARK: - readExistingFile

    /// 验证读取已有文件（/etc/hostname）返回非空数据且为合法 UTF-8。
    @Test
    func readExistingFile() async throws {
        let config = try #require(IntegrationTestConfig.load())
        let client = try await config.connectSSH()
        defer { Task { await client.disconnect() } }

        let data = try await client.sftpReadFile(path: "/etc/hostname")
        #expect(!data.isEmpty)

        let text = String(data: data, encoding: .utf8)
        #expect(text != nil)
    }

    // MARK: - writeAndReadFile

    /// 验证写入文件后读取，内容与写入一致。测试后清理临时文件。
    @Test
    func writeAndReadFile() async throws {
        let config = try #require(IntegrationTestConfig.load())
        let client = try await config.connectSSH()
        defer { Task { await client.disconnect() } }

        let path = testFilePath()
        let content = "Hello ConchTalk SFTP \(UUID().uuidString)"
        let writeData = Data(content.utf8)

        try await client.sftpWriteFile(path: path, data: writeData)
        defer { Task { _ = try? await client.execute(command: "rm -f \(path)") } }

        let readData = try await client.sftpReadFile(path: path)
        #expect(readData == writeData)
    }

    // MARK: - writeFileToNonExistentDir

    /// 验证写入到不存在的目录时抛出错误（SFTP 不会自动创建中间目录）。
    @Test
    func writeFileToNonExistentDir() async throws {
        let config = try #require(IntegrationTestConfig.load())
        let client = try await config.connectSSH()
        defer { Task { await client.disconnect() } }

        let path = "/tmp/conchtalk-test-nested-\(UUID().uuidString)/a/b/file.txt"

        await #expect(throws: (any Error).self) {
            try await client.sftpWriteFile(path: path, data: Data("test".utf8))
        }
    }

    // MARK: - readNonExistentFile

    /// 验证读取不存在的文件时抛出错误。
    @Test
    func readNonExistentFile() async throws {
        let config = try #require(IntegrationTestConfig.load())
        let client = try await config.connectSSH()
        defer { Task { await client.disconnect() } }

        let path = "/tmp/conchtalk-nonexistent-\(UUID().uuidString)"

        await #expect(throws: (any Error).self) {
            try await client.sftpReadFile(path: path)
        }
    }

    // MARK: - fileSize

    /// 验证写入已知内容后，sftpFileSize 返回正确的字节数。
    @Test
    func fileSize() async throws {
        let config = try #require(IntegrationTestConfig.load())
        let client = try await config.connectSSH()
        defer { Task { await client.disconnect() } }

        let path = testFilePath()
        let content = "abcdef1234567890"
        let writeData = Data(content.utf8)

        try await client.sftpWriteFile(path: path, data: writeData)
        defer { Task { _ = try? await client.execute(command: "rm -f \(path)") } }

        let size = try await client.sftpFileSize(path: path)
        #expect(size == UInt64(writeData.count))
    }
}
