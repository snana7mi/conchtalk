/// 文件说明：SSHExecutionIntegrationTests，SSH 命令执行的集成测试。
@testable import ConchTalk
import Foundation
import Testing

/// SSHExecutionIntegrationTests：
/// 验证 NIOSSHClient 的命令执行能力，包括标准输出、标准错误、退出码、
/// 流式输出、超时和 ANSI 转义序列等场景。
/// 需要设置环境变量（CT_TEST_HOST 等）才能运行，否则自动跳过。
@Suite(.tags(.integration), .serialized, .enabled(if: IntegrationTestConfig.isAvailable))
struct SSHExecutionIntegrationTests {

    // MARK: - executeSimpleCommand

    /// 验证简单 echo 命令返回预期输出。
    @Test
    func executeSimpleCommand() async throws {
        let config = try #require(IntegrationTestConfig.load())
        let client = try await config.connectSSH()
        defer { Task { await client.disconnect() } }

        let output = try await client.execute(command: "echo hello")
        #expect(output.trimmingCharacters(in: .whitespacesAndNewlines) == "hello")
    }

    // MARK: - executeCommandWithStderr

    /// 验证 stderr 输出在退出码为 0 时被捕获，输出包含 "err"。
    @Test
    func executeCommandWithStderr() async throws {
        let config = try #require(IntegrationTestConfig.load())
        let client = try await config.connectSSH()
        defer { Task { await client.disconnect() } }

        let output = try await client.execute(command: "echo err >&2")
        #expect(output.contains("err"))
    }

    // MARK: - executeStdoutAndStderr

    /// 验证同时包含 stdout 和 stderr 的命令，stderr 带有 [stderr] 标记合并输出。
    @Test
    func executeStdoutAndStderr() async throws {
        let config = try #require(IntegrationTestConfig.load())
        let client = try await config.connectSSH()
        defer { Task { await client.disconnect() } }

        let output = try await client.execute(command: "echo out && echo err >&2")
        #expect(output.contains("out"))
        #expect(output.contains("[stderr]"))
        #expect(output.contains("err"))
    }

    // MARK: - executeNonZeroExitCode

    /// 验证非零退出码抛出 SSHError.commandFailed，错误信息包含退出码 "42"。
    @Test
    func executeNonZeroExitCode() async throws {
        let config = try #require(IntegrationTestConfig.load())
        let client = try await config.connectSSH()
        defer { Task { await client.disconnect() } }

        do {
            _ = try await client.execute(command: "exit 42")
            Issue.record("Expected SSHError.commandFailed but command succeeded")
        } catch let error as SSHError {
            guard case .commandFailed(let message) = error else {
                Issue.record("Expected SSHError.commandFailed but got \(error)")
                return
            }
            #expect(message.contains("42"))
        }
    }

    // MARK: - executeStreamingOutput

    /// 验证流式输出能逐块返回多个值，包含 1、2、3。
    @Test
    func executeStreamingOutput() async throws {
        let config = try #require(IntegrationTestConfig.load())
        let client = try await config.connectSSH()
        defer { Task { await client.disconnect() } }

        let stream = client.executeStreaming(command: "for i in 1 2 3; do echo $i; sleep 0.2; done")
        var chunks: [String] = []
        for try await chunk in stream {
            chunks.append(chunk)
        }

        let combined = chunks.joined()
        #expect(chunks.count >= 1)
        #expect(combined.contains("1"))
        #expect(combined.contains("2"))
        #expect(combined.contains("3"))
    }

    // MARK: - executeLongRunningTimeout

    /// 验证长时间运行的命令在超时后抛出超时相关错误。
    @Test
    func executeLongRunningTimeout() async throws {
        let config = try #require(IntegrationTestConfig.load())
        let client = try await config.connectSSH()
        defer { Task { await client.disconnect() } }

        await #expect(throws: (any Error).self) {
            _ = try await client.execute(command: "sleep 999", timeout: 3)
        }
    }

    // MARK: - executeMultipleCommandsSequential

    /// 验证三个连续的 echo 命令都能成功执行并返回正确结果。
    @Test
    func executeMultipleCommandsSequential() async throws {
        let config = try #require(IntegrationTestConfig.load())
        let client = try await config.connectSSH()
        defer { Task { await client.disconnect() } }

        let output1 = try await client.execute(command: "echo first")
        let output2 = try await client.execute(command: "echo second")
        let output3 = try await client.execute(command: "echo third")

        #expect(output1.trimmingCharacters(in: .whitespacesAndNewlines).contains("first"))
        #expect(output2.trimmingCharacters(in: .whitespacesAndNewlines).contains("second"))
        #expect(output3.trimmingCharacters(in: .whitespacesAndNewlines).contains("third"))
    }

    // MARK: - executeCommandWithANSIOutput

    /// 验证包含 ANSI 转义序列的命令输出非空。
    @Test
    func executeCommandWithANSIOutput() async throws {
        let config = try #require(IntegrationTestConfig.load())
        let client = try await config.connectSSH()
        defer { Task { await client.disconnect() } }

        let output = try await client.execute(command: "printf '\\033[31mred\\033[0m'")
        #expect(!output.isEmpty)
    }

    // MARK: - 超时行为（问题 4）

    /// 超时命令在 timeout + 宽限期 + 余量内抛 SSHError.timeout，调用方不被无限阻塞。
    @Test
    func executeTimeoutReturnsWithinBound() async throws {
        let config = try #require(IntegrationTestConfig.load())
        let client = try await config.connectSSH()
        defer { Task { await client.disconnect() } }

        let start = ContinuousClock.now
        do {
            _ = try await client.execute(command: "sleep 100", timeout: 3)
            Issue.record("Expected SSHError.timeout but command succeeded")
        } catch let error as SSHError {
            guard case .timeout = error else {
                Issue.record("Expected SSHError.timeout but got \(error)")
                return
            }
        }
        // timeout(3s) + 宽限(5s) + 余量(2s) = 10s 上界
        #expect(ContinuousClock.now - start < .seconds(10))
    }

    /// 输出持续流动的命令超时后及时返回（checkCancellation 生效），且连接保持可用（watchdog 未触发）。
    @Test
    func executeTimeoutWithFlowingOutputCancelsPromptly() async throws {
        let config = try #require(IntegrationTestConfig.load())
        let client = try await config.connectSSH()
        defer { Task { await client.disconnect() } }

        let start = ContinuousClock.now
        do {
            _ = try await client.execute(
                command: "while true; do echo x; sleep 0.1; done", timeout: 2)
            Issue.record("Expected SSHError.timeout but command succeeded")
        } catch let error as SSHError {
            guard case .timeout = error else {
                Issue.record("Expected SSHError.timeout but got \(error)")
                return
            }
        }
        // 可取消路径应在宽限期内退出（取 2s timeout + 5s 宽限的上界再放余量）
        #expect(ContinuousClock.now - start < .seconds(9))

        // 连接保持可用：watchdog 不应触发强断
        let followUp = try await client.execute(command: "echo ok")
        #expect(followUp.contains("ok"))
        let stillConnected = await client.isConnected
        #expect(stillConnected)
    }

    /// 超时后连接整体仍可继续执行后续命令（回归：宽限 watchdog 不误关健康连接）。
    @Test
    func executeAfterTimeoutConnectionSurvives() async throws {
        let config = try #require(IntegrationTestConfig.load())
        let client = try await config.connectSSH()
        defer { Task { await client.disconnect() } }

        _ = try? await client.execute(command: "sleep 30", timeout: 2)
        // 等待越过宽限期，确认 watchdog 对「可取消的正常超时」不触发
        try await Task.sleep(for: .seconds(6))
        let output = try await client.execute(command: "echo survived")
        #expect(output.contains("survived"))
    }
}
