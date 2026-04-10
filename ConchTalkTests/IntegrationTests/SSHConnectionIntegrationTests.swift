/// 文件说明：SSHConnectionIntegrationTests，SSH 连接认证的集成测试。
@testable import ConchTalk
import Foundation
import Testing

/// SSHConnectionIntegrationTests：
/// 验证 NIOSSHClient 的连接、断开、认证失败和不可达主机等场景。
/// 需要设置环境变量（CT_TEST_HOST 等）才能运行，否则自动跳过。
@Suite(.tags(.integration), .serialized)
struct SSHConnectionIntegrationTests {

    // MARK: - connectWithPassword

    /// 验证使用正确密码连接后，isConnected 为 true。
    @Test
    func connectWithPassword() async throws {
        let config = try #require(IntegrationTestConfig.load())
        let client = NIOSSHClient()
        defer { Task { await client.disconnect() } }

        let server = config.makeServer()
        try await client.connect(
            to: server,
            password: config.password,
            sshKeyData: nil,
            keyPassphrase: nil
        )

        let connected = await client.isConnected
        #expect(connected == true)
    }

    // MARK: - disconnectCleanly

    /// 验证断开连接后，isConnected 变为 false。
    @Test
    func disconnectCleanly() async throws {
        let config = try #require(IntegrationTestConfig.load())
        let client = NIOSSHClient()

        let server = config.makeServer()
        try await client.connect(
            to: server,
            password: config.password,
            sshKeyData: nil,
            keyPassphrase: nil
        )

        await client.disconnect()

        let connected = await client.isConnected
        #expect(connected == false)
    }

    // MARK: - connectWithWrongPassword

    /// 验证使用错误密码连接时抛出 SSHError。
    /// Citadel 的密码认证失败会通过 ChannelError.eof 表现，NIOSSHClient 将其归类为 SSHError.connectionFailed。
    @Test
    func connectWithWrongPassword() async throws {
        let config = try #require(IntegrationTestConfig.load())
        let client = NIOSSHClient()
        defer { Task { await client.disconnect() } }

        let server = config.makeServer()

        await #expect(throws: SSHError.self) {
            try await client.connect(
                to: server,
                password: "definitely-wrong-password-\(UUID().uuidString)",
                sshKeyData: nil,
                keyPassphrase: nil
            )
        }
    }

    // MARK: - connectToUnreachableHost

    /// 验证连接不可达主机时抛出 SSHError.connectionFailed。
    /// 使用 RFC 5737 文档地址 192.0.2.1，保证不可达。此测试可能需要较长时间（连接超时）。
    @Test
    func connectToUnreachableHost() async throws {
        _ = try #require(IntegrationTestConfig.load())
        let client = NIOSSHClient()
        defer { Task { await client.disconnect() } }

        let unreachableServer = Server(
            name: "Unreachable",
            host: "192.0.2.1",
            port: 22,
            username: "test",
            authMethod: .password
        )

        await #expect(throws: SSHError.self) {
            try await client.connect(
                to: unreachableServer,
                password: "irrelevant",
                sshKeyData: nil,
                keyPassphrase: nil
            )
        }
    }

    // MARK: - reconnectAfterDisconnect

    /// 验证断开后可以使用同一客户端实例重新连接。
    @Test
    func reconnectAfterDisconnect() async throws {
        let config = try #require(IntegrationTestConfig.load())
        let client = NIOSSHClient()
        defer { Task { await client.disconnect() } }

        let server = config.makeServer()

        // 第一次连接
        try await client.connect(
            to: server,
            password: config.password,
            sshKeyData: nil,
            keyPassphrase: nil
        )
        let firstConnected = await client.isConnected
        #expect(firstConnected == true)

        // 断开
        await client.disconnect()
        let disconnected = await client.isConnected
        #expect(disconnected == false)

        // 重新连接
        try await client.connect(
            to: server,
            password: config.password,
            sshKeyData: nil,
            keyPassphrase: nil
        )
        let reconnected = await client.isConnected
        #expect(reconnected == true)
    }
}
