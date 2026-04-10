/// 文件说明：KeepAliveIntegrationTests，SSH 连接保活机制的集成测试。
@testable import ConchTalk
import Foundation
import Testing

/// KeepAliveIntegrationTests：
/// 验证 NIOSSHClient 的 keep-alive 机制能保持空闲连接存活，
/// 以及断线后 isConnected 状态正确更新。
/// 这些测试需要较长时间运行（60+ 秒）。
@Suite(.tags(.integration), .serialized)
struct KeepAliveIntegrationTests {

    // MARK: - keepAlivePings

    /// 连接后等待 35 秒（超过一个 keep-alive 周期 30 秒），验证连接仍然存活。
    @Test
    func keepAlivePings() async throws {
        let config = try #require(IntegrationTestConfig.load())
        let client = try await config.connectSSH()
        defer { Task { await client.disconnect() } }

        // 等待 35 秒，让至少一次 keep-alive ping 触发
        try await Task.sleep(for: .seconds(35))

        let connected = await client.isConnected
        #expect(connected == true, "连接应在 keep-alive 保活下保持存活")

        // 进一步验证：执行命令确认连接可用
        let output = try await client.execute(command: "echo alive")
        #expect(output.trimmingCharacters(in: .whitespacesAndNewlines) == "alive")
    }

    // MARK: - connectionStaysAlive

    /// 在 0 秒、30 秒、60 秒分别执行命令，验证长时间保活下连接始终可用。
    @Test
    func connectionStaysAlive() async throws {
        let config = try #require(IntegrationTestConfig.load())
        let client = try await config.connectSSH()
        defer { Task { await client.disconnect() } }

        // 第一次：0 秒
        let out1 = try await client.execute(command: "echo t0")
        #expect(out1.trimmingCharacters(in: .whitespacesAndNewlines) == "t0")

        // 第二次：等待 30 秒后
        try await Task.sleep(for: .seconds(30))
        let out2 = try await client.execute(command: "echo t30")
        #expect(out2.trimmingCharacters(in: .whitespacesAndNewlines) == "t30")

        // 第三次：再等待 30 秒后（总计 60 秒）
        try await Task.sleep(for: .seconds(30))
        let out3 = try await client.execute(command: "echo t60")
        #expect(out3.trimmingCharacters(in: .whitespacesAndNewlines) == "t60")

        let connected = await client.isConnected
        #expect(connected == true, "60 秒后连接应仍然存活")
    }

    // MARK: - keepAliveDetectsDisconnect

    /// 通过服务端杀死 SSH 进程来模拟断线，验证 isConnected 最终变为 false。
    /// 使用第二个 SSH 连接来执行 kill 命令。
    @Test
    func keepAliveDetectsDisconnect() async throws {
        let config = try #require(IntegrationTestConfig.load())

        // 被测连接：连接后获取自身 SSH 进程 PID
        let targetClient = try await config.connectSSH()

        // 获取被测连接的 sshd 子进程 PID（当前 shell 的父进程）
        let pidOutput = try await targetClient.execute(command: "echo $$")
        let shellPid = pidOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(!shellPid.isEmpty, "应能获取 shell PID")

        // 获取父进程（sshd fork 出的子进程）PID
        let ppidOutput = try await targetClient.execute(command: "ps -o ppid= -p $$ | tr -d ' '")
        let sshdPid = ppidOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(!sshdPid.isEmpty, "应能获取 sshd 子进程 PID")

        // 用第二个连接去 kill 被测连接的 sshd 进程
        let killerClient = try await config.connectSSH()
        defer { Task { await killerClient.disconnect() } }

        _ = try await killerClient.execute(command: "kill -9 \(sshdPid) 2>/dev/null || true")

        // 等待 keep-alive 检测到断线（最多等 45 秒，keep-alive 间隔 30 秒）
        var detected = false
        for _ in 0..<45 {
            try await Task.sleep(for: .seconds(1))
            let connected = await targetClient.isConnected
            if !connected {
                detected = true
                break
            }
        }

        #expect(detected, "kill 服务端进程后，isConnected 应最终变为 false")
    }
}
