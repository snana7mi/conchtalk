/// 文件说明：SSHClientProtocol，定义 SSH 连接生命周期与远端命令执行契约。
import Foundation

/// SSHClientProtocol：
/// 抽象 SSH 客户端核心能力，供上层统一管理连接、执行命令并观察连接状态。
protocol SSHClientProtocol: Sendable {
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
    /// - Parameter command: 待执行命令。
    /// - Returns: 命令输出文本。
    /// - Throws: 未连接、执行失败或通道异常时抛出。
    func execute(command: String) async throws -> String

    /// 当前连接状态。
    /// - Returns: `true` 表示可用连接已建立。
    var isConnected: Bool { get async }
}
