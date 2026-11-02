/// 文件说明：SSHClientProtocol，定义 SSH 连接生命周期与远端命令执行契约。
import Foundation

/// SSHClientProtocol：
/// 抽象 SSH 客户端核心能力，供上层统一管理连接、执行命令并观察连接状态。
nonisolated protocol SSHClientProtocol: Sendable {
    /// 建立到目标服务器的 SSH 连接。
    /// - Parameters:
    ///   - server: 目标服务器信息。
    ///   - password: 密码登录凭据（使用密码认证时提供）。
    ///   - sshKeyData: 私钥数据（使用密钥认证时提供）。
    ///   - keyPassphrase: 私钥口令（加密私钥时提供）。
    /// - Throws: 认证失败、网络失败或握手失败时抛出。
    func connect(to server: Server, password: String?, sshKeyData: Data?, keyPassphrase: String?) async throws

    /// 断开当前 SSH 连接并清理会话资源。
    func disconnect() async

    /// 在远端执行 Shell 命令。
    /// - Parameters:
    ///   - command: 待执行命令。
    ///   - timeout: 超时时间（秒）。
    ///   - reclaimOnTimeout: 为 true 时，超时后结束远端进程组并保留 SSH 连接。
    /// - Returns: 命令输出文本。
    /// - Throws: 未连接、执行失败、超时或通道异常时抛出。
    func execute(command: String, timeout: TimeInterval, reclaimOnTimeout: Bool) async throws -> String

    /// 以流式方式在远端执行 Shell 命令，逐块返回输出。
    /// - Parameter command: 待执行命令。
    /// - Returns: 异步抛出流，每个元素为一段输出文本。
    func executeStreaming(command: String) -> AsyncThrowingStream<String, Error>

    /// 关联的服务器 ID（由 SSHSessionManager 在注册时设置）。
    var serverID: UUID? { get async }

    /// 当前连接状态。
    /// - Returns: `true` 表示可用连接已建立。
    var isConnected: Bool { get async }

    /// 远端服务器能力探测结果。
    var serverCapabilities: ServerCapabilities { get async }

    // MARK: - SFTP

    /// 通过 SFTP 读取远端文件内容。
    /// - Parameter path: 远端文件绝对路径。
    /// - Returns: 文件二进制内容。
    /// - Throws: 文件不存在、权限不足或 SFTP 通道失败时抛出。
    func sftpReadFile(path: String) async throws -> Data

    /// 只读取文件开头的若干字节，用于在装入全文之前判断二进制或超限。
    /// - Parameters:
    ///   - path: 远端文件绝对路径。
    ///   - maxBytes: 最多读取的字节数。
    func sftpReadPrefix(path: String, maxBytes: Int) async throws -> Data

    /// 通过 SFTP 将数据写入远端文件。
    /// - Parameters:
    ///   - path: 远端文件绝对路径。
    ///   - data: 待写入的二进制数据。
    /// - Throws: 路径不可写、权限不足或 SFTP 通道失败时抛出。
    func sftpWriteFile(path: String, data: Data) async throws

    /// 通过 SFTP 获取远端文件大小（字节）。
    /// - Parameter path: 远端文件绝对路径。
    /// - Returns: 文件大小（字节数）。
    /// - Throws: 文件不存在或 SFTP 通道失败时抛出。
    func sftpFileSize(path: String) async throws -> UInt64

    /// 通过 SFTP 列出目录。不跟随 `..` 逃逸；由调用方传入已规范化的路径。
    func sftpListDirectory(path: String) async throws -> [RemoteFileEntry]

    /// 分块 SFTP 写入，支持进度回调。
    /// - Parameters:
    ///   - path: 远端文件路径。
    ///   - data: 待写入的完整数据。
    ///   - chunkSize: 每次写入的块大小（字节），默认 256KB。
    ///   - onProgress: 进度回调，参数为已写入字节数和总字节数。
    func sftpWriteFileChunked(
        path: String,
        data: Data,
        chunkSize: Int,
        onProgress: @escaping @Sendable (Int64, Int64) async -> Void
    ) async throws
}

// MARK: - Default Implementations

extension SSHClientProtocol {
    /// 不回收远端进程的执行。内部短命令走这里。
    func execute(command: String, timeout: TimeInterval) async throws -> String {
        try await execute(command: command, timeout: timeout, reclaimOnTimeout: false)
    }

    /// 带默认超时的 `execute` 便捷调用（保持后向兼容）。
    func execute(command: String) async throws -> String {
        try await execute(command: command, timeout: 120, reclaimOnTimeout: false)
    }

    /// `executeStreaming` 的默认实现：回退到非流式 `execute`，一次性返回全部输出。
    func executeStreaming(command: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let result = try await self.execute(command: command)
                    continuation.yield(result)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// `serverID` 默认实现：返回 nil。
    var serverID: UUID? {
        get async { nil }
    }

    /// `serverCapabilities` 默认实现：返回未知状态。
    var serverCapabilities: ServerCapabilities {
        get async { .unknown }
    }

    /// SFTP 默认实现：不支持时抛出错误。
    func sftpReadFile(path: String) async throws -> Data {
        throw SSHError.commandFailed("SFTP not supported")
    }

    /// 默认前缀读取：读全文再截断。真实客户端应覆盖成只读前缀。
    func sftpReadPrefix(path: String, maxBytes: Int) async throws -> Data {
        let data = try await sftpReadFile(path: path)
        if maxBytes <= 0 { return Data() }
        if data.count <= maxBytes { return data }
        return Data(data.prefix(maxBytes))
    }

    func sftpWriteFile(path: String, data: Data) async throws {
        throw SSHError.commandFailed("SFTP not supported")
    }

    func sftpFileSize(path: String) async throws -> UInt64 {
        throw SSHError.commandFailed("SFTP not supported")
    }

    func sftpListDirectory(path: String) async throws -> [RemoteFileEntry] {
        throw SSHError.commandFailed("SFTP not supported")
    }

    func sftpWriteFileChunked(
        path: String,
        data: Data,
        chunkSize: Int = 256 * 1024,
        onProgress: @Sendable (Int64, Int64) async -> Void
    ) async throws {
        throw SSHError.commandFailed("SFTP not supported")
    }
}
