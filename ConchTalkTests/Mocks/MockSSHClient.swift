/// 文件说明：MockSSHClient，测试用 SSH 客户端模拟，支持调用记录与错误注入。
@testable import ConchTalk
import Foundation

/// MockSSHClient：
/// 实现 SSHClientProtocol 的测试替身，支持配置返回值、记录调用历史与注入错误。
final class MockSSHClient: SSHClientProtocol, @unchecked Sendable {

    // MARK: - 调用记录

    struct CallRecord: Sendable {
        let method: String
        let arguments: [String: String]
    }

    private(set) var callHistory: [CallRecord] = []
    private(set) var executedCommands: [String] = []

    // MARK: - 可配置行为

    var connectError: Error?
    var executeResult: String = ""
    var executeResults: [String] = []
    private var executeResultIndex = 0
    var executeError: Error?
    var _isConnected: Bool = false
    var _serverCapabilities: ServerCapabilities = .unknown
    var sftpReadResult: Data = Data()
    var sftpReadError: Error?
    var sftpWriteError: Error?
    var sftpFileSizeResult: UInt64 = 0
    var sftpFileSizeError: Error?
    var sftpWriteChunkedError: Error?
    var streamingOutput: [String] = []
    var streamingError: Error?

    // MARK: - SSHClientProtocol

    func connect(to server: Server, password: String?, sshKeyData: Data?, keyPassphrase: String?) async throws {
        let (host, port, username) = await MainActor.run {
            (server.host, server.port, server.username)
        }
        callHistory.append(CallRecord(
            method: "connect",
            arguments: [
                "host": host,
                "port": "\(port)",
                "username": username
            ]
        ))
        if let error = connectError {
            throw error
        }
        _isConnected = true
    }

    func disconnect() async {
        callHistory.append(CallRecord(method: "disconnect", arguments: [:]))
        _isConnected = false
    }

    func execute(command: String, timeout: TimeInterval) async throws -> String {
        callHistory.append(CallRecord(
            method: "execute",
            arguments: ["command": command, "timeout": "\(timeout)"]
        ))
        executedCommands.append(command)
        if let error = executeError {
            throw error
        }
        if !executeResults.isEmpty {
            let result = executeResults[min(executeResultIndex, executeResults.count - 1)]
            executeResultIndex += 1
            return result
        }
        return executeResult
    }

    func executeStreaming(command: String) -> AsyncThrowingStream<String, Error> {
        callHistory.append(CallRecord(
            method: "executeStreaming",
            arguments: ["command": command]
        ))
        let output = streamingOutput
        let error = streamingError
        return AsyncThrowingStream { continuation in
            Task {
                for chunk in output {
                    continuation.yield(chunk)
                }
                if let error {
                    continuation.finish(throwing: error)
                } else {
                    continuation.finish()
                }
            }
        }
    }

    var isConnected: Bool {
        get async { _isConnected }
    }

    var serverCapabilities: ServerCapabilities {
        get async { _serverCapabilities }
    }

    // MARK: - SFTP

    func sftpReadFile(path: String) async throws -> Data {
        callHistory.append(CallRecord(method: "sftpReadFile", arguments: ["path": path]))
        if let error = sftpReadError { throw error }
        return sftpReadResult
    }

    func sftpWriteFile(path: String, data: Data) async throws {
        callHistory.append(CallRecord(method: "sftpWriteFile", arguments: ["path": path]))
        if let error = sftpWriteError { throw error }
    }

    func sftpFileSize(path: String) async throws -> UInt64 {
        callHistory.append(CallRecord(method: "sftpFileSize", arguments: ["path": path]))
        if let error = sftpFileSizeError { throw error }
        return sftpFileSizeResult
    }

    func sftpWriteFileChunked(
        path: String,
        data: Data,
        chunkSize: Int,
        onProgress: @escaping @Sendable (Int64, Int64) async -> Void
    ) async throws {
        callHistory.append(CallRecord(method: "sftpWriteFileChunked", arguments: ["path": path]))
        if let error = sftpWriteChunkedError { throw error }
        await onProgress(Int64(data.count), Int64(data.count))
    }

    // MARK: - 辅助方法

    /// 重置所有调用记录和配置。
    func reset() {
        callHistory = []
        executedCommands = []
        executeResultIndex = 0
        connectError = nil
        executeResult = ""
        executeResults = []
        executeError = nil
        _isConnected = false
        _serverCapabilities = .unknown
        sftpReadResult = Data()
        sftpReadError = nil
        sftpWriteError = nil
        sftpFileSizeResult = 0
        sftpFileSizeError = nil
        sftpWriteChunkedError = nil
        streamingOutput = []
        streamingError = nil
    }

    /// 检查是否调用过指定方法。
    func didCall(_ method: String) -> Bool {
        callHistory.contains { $0.method == method }
    }

    /// 返回指定方法的调用次数。
    func callCount(_ method: String) -> Int {
        callHistory.filter { $0.method == method }.count
    }
}
