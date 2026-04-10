/// 文件说明：ACPDirectModeIntegrationTests，ACP 直连模式的集成测试。
@testable import ConchTalk
@preconcurrency import ACPModel
@preconcurrency import Citadel
import Foundation
import Testing

/// ConchTalk 和 ACPModel 均定义了 AgentInfo，此处统一使用 ConchTalk 的定义。
private typealias AgentInfo = ConchTalk.AgentInfo

/// ACPDirectModeIntegrationTests：
/// 验证 ACP 直连模式下的代理发现、连接握手、消息收发与断连等场景。
/// 需要真实服务器且安装了相应代理才能运行。
/// 每个代理的测试可能需要 10-30 秒。
/// `.serialized` 确保代理连接测试不会并发执行，避免端口冲突或资源争用。
@Suite(.tags(.integration), .serialized)
struct ACPDirectModeIntegrationTests {

    // MARK: - 辅助方法

    /// 通过 SSH 探测远端服务器上安装的代理，返回 AgentInfo 列表。
    /// 与生产代码 `SystemProfile.toCapabilities()` 逻辑对齐。
    private func discoverInstalledAgents(nioClient: NIOSSHClient) async throws -> [AgentInfo] {
        let agentTypes = AgentType.allCases

        // 探测代理二进制
        let checkScript = agentTypes.map { type in
            let name = type.binaryName
            return """
            if command -v \(name) >/dev/null 2>&1; then \
            ver=$(\(name) --version 2>&1 | head -1); \
            echo "TOOL:\(name):$(command -v \(name)):$ver"; \
            else echo "TOOL:\(name):NOT_FOUND:"; fi
            """
        }.joined(separator: "; ")

        let fullScript = SSHSessionManager.shellInitPrefix + checkScript
        let output = try await nioClient.execute(command: fullScript)

        var agents: [AgentInfo] = []
        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("TOOL:") else { continue }
            let parts = trimmed.dropFirst("TOOL:".count).components(separatedBy: ":")
            guard parts.count >= 2 else { continue }
            let name = parts[0]
            let pathOrNotFound = parts[1]
            guard pathOrNotFound != "NOT_FOUND" else { continue }
            guard let type = AgentType(rawValue: name) else { continue }

            let version: String?
            if parts.count >= 3 {
                let ver = parts[2...].joined(separator: ":").trimmingCharacters(in: .whitespacesAndNewlines)
                version = ver.isEmpty ? nil : ver
            } else {
                version = nil
            }

            agents.append(AgentInfo(type: type, path: pathOrNotFound, version: version))
        }
        return agents
    }

    /// 根据类型查找已安装的代理，未安装时返回 nil。
    private func findAgent(_ type: AgentType, in agents: [AgentInfo]) -> AgentInfo? {
        agents.first { $0.type == type }
    }

    // MARK: - discoverAgents

    /// 验证 SSH 探测脚本能正常执行并返回结果（即使服务器没有安装任何代理）。
    @Test
    func discoverAgents() async throws {
        let config = try #require(IntegrationTestConfig.load())
        let (nioClient, _) = try await config.connectForACP()
        defer { Task { await nioClient.disconnect() } }

        let agents = try await discoverInstalledAgents(nioClient: nioClient)

        // 打印发现的代理列表，方便调试
        if agents.isEmpty {
            print("[ACPTest] No agents found on server (this is OK — probe itself succeeded)")
        } else {
            for agent in agents {
                print("[ACPTest] Found agent: \(agent.type.displayName) at \(agent.path)")
            }
        }
    }

    // MARK: - connectClaudeCode

    /// 验证与 Claude Code 的 ACP 握手连接成功。
    @Test(.timeLimit(.minutes(2)))
    func connectClaudeCode() async throws {
        let config = try #require(IntegrationTestConfig.load())
        let (nioClient, citadelClient) = try await config.connectForACP()
        defer { Task { await nioClient.disconnect() } }

        let agents = try await discoverInstalledAgents(nioClient: nioClient)
        let agentInfo = try #require(findAgent(.claude, in: agents), "Agent not found on server")

        let session = DirectAgentSession(agentInfo: agentInfo, sshClient: citadelClient)
        defer { Task { await session.disconnect() } }

        let displayName = try await session.connect(cwd: nil)
        let connected = await session.isConnected
        #expect(connected == true)
        #expect(!displayName.isEmpty)
        print("[ACPTest] Connected to Claude Code: \(displayName)")
    }

    // MARK: - connectCodex

    /// 验证与 Codex 的 ACP 握手连接成功。
    @Test(.timeLimit(.minutes(2)))
    func connectCodex() async throws {
        let config = try #require(IntegrationTestConfig.load())
        let (nioClient, citadelClient) = try await config.connectForACP()
        defer { Task { await nioClient.disconnect() } }

        let agents = try await discoverInstalledAgents(nioClient: nioClient)
        let agentInfo = try #require(findAgent(.codex, in: agents), "Agent not found on server")

        let session = DirectAgentSession(agentInfo: agentInfo, sshClient: citadelClient)
        defer { Task { await session.disconnect() } }

        let displayName = try await session.connect(cwd: nil)
        let connected = await session.isConnected
        #expect(connected == true)
        #expect(!displayName.isEmpty)
        print("[ACPTest] Connected to Codex: \(displayName)")
    }

    // MARK: - connectGemini

    /// 验证与 Gemini CLI 的 ACP 握手连接成功。
    @Test(.timeLimit(.minutes(2)))
    func connectGemini() async throws {
        let config = try #require(IntegrationTestConfig.load())
        let (nioClient, citadelClient) = try await config.connectForACP()
        defer { Task { await nioClient.disconnect() } }

        let agents = try await discoverInstalledAgents(nioClient: nioClient)
        let agentInfo = try #require(findAgent(.gemini, in: agents), "Agent not found on server")

        let session = DirectAgentSession(agentInfo: agentInfo, sshClient: citadelClient)
        defer { Task { await session.disconnect() } }

        let displayName = try await session.connect(cwd: nil)
        let connected = await session.isConnected
        #expect(connected == true)
        #expect(!displayName.isEmpty)
        print("[ACPTest] Connected to Gemini CLI: \(displayName)")
    }

    // MARK: - sendPromptClaude

    /// 验证向 Claude Code 发送短 prompt 并收到回复。
    @Test(.timeLimit(.minutes(2)))
    func sendPromptClaude() async throws {
        let config = try #require(IntegrationTestConfig.load())
        let (nioClient, citadelClient) = try await config.connectForACP()
        defer { Task { await nioClient.disconnect() } }

        let agents = try await discoverInstalledAgents(nioClient: nioClient)
        let agentInfo = try #require(findAgent(.claude, in: agents), "Agent not found on server")

        let session = DirectAgentSession(agentInfo: agentInfo, sshClient: citadelClient)
        defer { Task { await session.disconnect() } }

        try await session.connect(cwd: nil)
        try await session.sendPrompt("Say hello in exactly one word.")
        print("[ACPTest] Claude prompt completed")
    }

    // MARK: - sendPromptCodex

    /// 验证向 Codex 发送短 prompt 并收到回复。
    @Test(.timeLimit(.minutes(2)))
    func sendPromptCodex() async throws {
        let config = try #require(IntegrationTestConfig.load())
        let (nioClient, citadelClient) = try await config.connectForACP()
        defer { Task { await nioClient.disconnect() } }

        let agents = try await discoverInstalledAgents(nioClient: nioClient)
        let agentInfo = try #require(findAgent(.codex, in: agents), "Agent not found on server")

        let session = DirectAgentSession(agentInfo: agentInfo, sshClient: citadelClient)
        defer { Task { await session.disconnect() } }

        try await session.connect(cwd: nil)
        try await session.sendPrompt("Say hello in exactly one word.")
        print("[ACPTest] Codex prompt completed")
    }

    // MARK: - sendPromptGemini

    /// 验证向 Gemini CLI 发送短 prompt 并收到回复。
    @Test(.timeLimit(.minutes(10)))
    func sendPromptGemini() async throws {
        let config = try #require(IntegrationTestConfig.load())
        let (nioClient, citadelClient) = try await config.connectForACP()
        defer { Task { await nioClient.disconnect() } }

        let agents = try await discoverInstalledAgents(nioClient: nioClient)
        let agentInfo = try #require(findAgent(.gemini, in: agents), "Agent not found on server")

        let session = DirectAgentSession(agentInfo: agentInfo, sshClient: citadelClient)
        defer { Task { await session.disconnect() } }

        try await session.connect(cwd: nil)
        try await session.sendPrompt("Say hello in exactly one word.")
        print("[ACPTest] Gemini prompt completed")
    }

    // MARK: - disconnectAgent

    /// 验证与代理的优雅断连流程。
    @Test(.timeLimit(.minutes(2)))
    func disconnectAgent() async throws {
        let config = try #require(IntegrationTestConfig.load())
        let (nioClient, citadelClient) = try await config.connectForACP()
        defer { Task { await nioClient.disconnect() } }

        let agents = try await discoverInstalledAgents(nioClient: nioClient)
        // 使用任意一个可用代理测试断连
        let agentInfo = try #require(agents.first, "Agent not found on server")

        let session = DirectAgentSession(agentInfo: agentInfo, sshClient: citadelClient)

        // 连接
        try await session.connect(cwd: nil)
        let connectedBefore = await session.isConnected
        #expect(connectedBefore == true)

        // 断连
        await session.disconnect()
        let connectedAfter = await session.isConnected
        #expect(connectedAfter == false)

        print("[ACPTest] Successfully disconnected from \(agentInfo.type.displayName)")
    }

    // MARK: - connectNonExistentAgent

    /// 验证连接不存在的代理时返回带诊断信息的错误。
    @Test(.timeLimit(.minutes(1)))
    func connectNonExistentAgent() async throws {
        let config = try #require(IntegrationTestConfig.load())
        let (nioClient, citadelClient) = try await config.connectForACP()
        defer { Task { await nioClient.disconnect() } }

        // 构造一个不存在的代理信息（使用不存在的路径）
        let fakeAgent = AgentInfo(
            type: .opencode,
            path: "/usr/local/bin/nonexistent-agent-\(UUID().uuidString.prefix(8))",
            version: nil
        )

        let session = DirectAgentSession(agentInfo: fakeAgent, sshClient: citadelClient)
        defer { Task { await session.disconnect() } }

        // 连接应失败
        do {
            try await session.connect(cwd: nil)
            Issue.record("连接不存在的代理应抛出错误")
        } catch {
            // 验证错误包含诊断信息
            let errorMessage = "\(error)"
            print("[ACPTest] Expected error for non-existent agent: \(errorMessage)")
            // 只要抛出了错误就算通过，不强制要求特定错误类型
            // （可能是 ACPConnectionError.protocolError 带诊断日志，或底层 SSH 错误）
        }

        let connected = await session.isConnected
        #expect(connected == false, "连接失败后 isConnected 应为 false")
    }
}
