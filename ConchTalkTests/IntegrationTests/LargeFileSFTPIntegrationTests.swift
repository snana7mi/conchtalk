/// 文件说明：LargeFileSFTPIntegrationTests，大文件 SFTP 传输的集成测试。
@testable import ConchTalk
import CryptoKit
import Foundation
import Testing

/// LargeFileSFTPIntegrationTests：
/// 验证 NIOSSHClient 的 SFTP 大文件读写和分块传输功能，
/// 包括 1MB/10MB 文件上传、分块进度回调和大文件下载校验。
@Suite(.tags(.integration), .serialized)
struct LargeFileSFTPIntegrationTests {

    // MARK: - Helpers

    /// 生成唯一的临时文件路径，避免测试间冲突。
    private func testFilePath() -> String {
        "/tmp/conchtalk-test-large-\(UUID().uuidString)"
    }

    /// 计算数据的 SHA256 哈希值，用于大文件内容比对。
    private func sha256Hash(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - upload1MBFile

    /// 生成 1MB 随机数据，通过 SFTP 写入后读回，验证内容一致。
    @Test
    func upload1MBFile() async throws {
        let config = try #require(IntegrationTestConfig.load())
        let client = try await config.connectSSH()
        defer { Task { await client.disconnect() } }

        let path = testFilePath()
        let size = 1 * 1024 * 1024 // 1MB
        let data = Data((0..<size).map { _ in UInt8.random(in: 0...255) })

        try await client.sftpWriteFile(path: path, data: data)
        defer { Task { _ = try? await client.execute(command: "rm -f \(path)") } }

        let readBack = try await client.sftpReadFile(path: path)
        #expect(sha256Hash(readBack) == sha256Hash(data), "读回的 1MB 文件内容应与写入一致")
    }

    // MARK: - upload10MBFile

    // MARK: - chunkedProgressCallbacks

    /// 写入 5MB 数据，收集分块进度回调，验证回调被多次调用且最终进度正确。
    @Test
    func chunkedProgressCallbacks() async throws {
        let config = try #require(IntegrationTestConfig.load())
        let client = try await config.connectSSH()
        defer { Task { await client.disconnect() } }

        let path = testFilePath()
        let size = 5 * 1024 * 1024 // 5MB
        let data = Data(count: size)
        let chunkSize = 256 * 1024 // 256KB

        // 使用 actor 安全地收集进度回调
        let collector = ProgressCollector()

        try await client.sftpWriteFileChunked(
            path: path,
            data: data,
            chunkSize: chunkSize,
            onProgress: { bytesWritten, totalBytes in
                await collector.record(bytesWritten: bytesWritten, totalBytes: totalBytes)
            }
        )
        defer { Task { _ = try? await client.execute(command: "rm -f \(path)") } }

        let records = await collector.records
        #expect(records.count > 1, "进度回调应被多次调用，实际调用 \(records.count) 次")

        // 验证最后一次回调的 bytesWritten 等于 totalBytes
        if let last = records.last {
            #expect(last.bytesWritten == last.totalBytes, "最终进度应等于总大小")
            #expect(last.totalBytes == Int64(size), "总大小应等于 5MB")
        }
    }

    // MARK: - downloadLargeFile

    /// 写入 5MB 数据后读回，通过 SHA256 哈希验证内容完整性。
    @Test
    func downloadLargeFile() async throws {
        let config = try #require(IntegrationTestConfig.load())
        let client = try await config.connectSSH()
        defer { Task { await client.disconnect() } }

        let path = testFilePath()
        let size = 5 * 1024 * 1024 // 5MB
        let data = Data((0..<size).map { _ in UInt8.random(in: 0...255) })
        let originalHash = sha256Hash(data)

        try await client.sftpWriteFile(path: path, data: data)
        defer { Task { _ = try? await client.execute(command: "rm -f \(path)") } }

        let downloaded = try await client.sftpReadFile(path: path)
        let downloadedHash = sha256Hash(downloaded)

        #expect(downloaded.count == size, "下载文件大小应为 5MB")
        #expect(downloadedHash == originalHash, "下载文件的 SHA256 哈希应与原始数据一致")
    }
}

// MARK: - ProgressCollector

/// 线程安全的进度回调收集器。
private actor ProgressCollector {
    struct Record {
        let bytesWritten: Int64
        let totalBytes: Int64
    }

    private(set) var records: [Record] = []

    func record(bytesWritten: Int64, totalBytes: Int64) {
        records.append(Record(bytesWritten: bytesWritten, totalBytes: totalBytes))
    }
}
