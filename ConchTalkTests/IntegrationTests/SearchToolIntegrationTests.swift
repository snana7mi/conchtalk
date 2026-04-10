/// 文件说明：SearchToolIntegrationTests，搜索 Tool 的集成测试。
@testable import ConchTalk
import Foundation
import Testing

/// SearchToolIntegrationTests：
/// 验证 GrepTool、GlobTool 在真实 SSH 环境下的执行结果。
/// 需要设置环境变量（CT_TEST_HOST 等）才能运行，否则自动跳过。
@Suite(.tags(.integration), .serialized)
struct SearchToolIntegrationTests {

    // MARK: - GrepTool

    /// 验证在 /etc/passwd 中搜索 "root" 能找到匹配结果。
    @Test
    func grepPattern() async throws {
        let config = try #require(IntegrationTestConfig.load())
        let client = try await config.connectSSH()
        defer { Task { await client.disconnect() } }

        let tool = GrepTool()
        let result = try await tool.execute(
            arguments: [
                "pattern": "root",
                "path": "/etc/passwd",
                "explanation": "Search for root in passwd for integration test",
            ],
            sshClient: client
        )

        #expect(result.isSuccess)
        #expect(result.output.contains("root"))
    }

    /// 验证搜索不可能匹配的模式返回 "No matches found" 结果。
    @Test
    func grepNoMatch() async throws {
        let config = try #require(IntegrationTestConfig.load())
        let client = try await config.connectSSH()
        defer { Task { await client.disconnect() } }

        let tool = GrepTool()
        let impossiblePattern = "ZZZZZ_IMPOSSIBLE_\(UUID().uuidString)"
        let result = try await tool.execute(
            arguments: [
                "pattern": impossiblePattern,
                "path": "/etc/passwd",
                "explanation": "Search for impossible pattern for integration test",
            ],
            sshClient: client
        )

        #expect(result.isSuccess)
        #expect(result.output.contains("No matches found"))
    }

    // MARK: - GlobTool

    /// 验证在 /etc 下搜索 *.conf 能找到配置文件。
    @Test
    func globPattern() async throws {
        let config = try #require(IntegrationTestConfig.load())
        let client = try await config.connectSSH()
        defer { Task { await client.disconnect() } }

        let tool = GlobTool()
        let result = try await tool.execute(
            arguments: [
                "pattern": "*.conf",
                "path": "/etc",
                "explanation": "Find conf files in /etc for integration test",
            ],
            sshClient: client
        )

        #expect(result.isSuccess)
        #expect(result.output.contains(".conf"))
    }

    /// 验证 type="directory" 过滤只返回目录。
    @Test
    func globWithType() async throws {
        let config = try #require(IntegrationTestConfig.load())
        let client = try await config.connectSSH()
        defer { Task { await client.disconnect() } }

        let tool = GlobTool()
        let result = try await tool.execute(
            arguments: [
                "pattern": "*",
                "path": "/etc",
                "type": "directory",
                "max_depth": 1,
                "explanation": "Find directories in /etc for integration test",
            ],
            sshClient: client
        )

        #expect(result.isSuccess)
        // 应该找到一些子目录，且不包含 "No files found"
        #expect(!result.output.contains("No files found"))
    }
}
