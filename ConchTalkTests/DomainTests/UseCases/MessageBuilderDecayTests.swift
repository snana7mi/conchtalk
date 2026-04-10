/// 文件说明：MessageBuilderDecayTests，验证 Tool Output 自动衰减逻辑。
import Foundation
import Testing
@testable import ConchTalk

@Suite("MessageBuilder Decay")
struct MessageBuilderDecayTests {

    // MARK: - Helpers

    /// 创建 N 轮对话历史（user + assistant with tool call），target 消息位于最前面。
    /// 轮次距离 = 后续的 user 消息数量。
    /// - Parameters:
    ///   - targetToolName: 目标 tool call 的名称
    ///   - targetToolOutput: 目标 tool call 的输出
    ///   - roundsAfter: 目标消息之后的对话轮数（决定轮次距离）
    /// - Returns: 包含 target 和填充轮次的消息数组
    private func makeHistory(
        targetToolName: String = "execute_ssh_command",
        targetToolOutput: String,
        roundsAfter: Int
    ) -> [Message] {
        var messages: [Message] = []

        // 目标 tool call 消息
        let toolCall = TestFixtures.makeToolCall(toolName: targetToolName)
        messages.append(TestFixtures.makeMessage(
            role: .command,
            content: "",
            toolCall: toolCall,
            toolOutput: targetToolOutput
        ))

        // 填充后续轮次（每轮 = user + assistant with tool call）
        for _ in 0..<roundsAfter {
            messages.append(TestFixtures.makeMessage(role: .user, content: "next"))
            let filler = TestFixtures.makeToolCall(
                id: UUID().uuidString,
                toolName: "read_file"
            )
            messages.append(TestFixtures.makeMessage(
                role: .command,
                content: "",
                toolCall: filler,
                toolOutput: "ok"
            ))
        }

        return messages
    }

    /// 创建包含 commandDenied 系统消息的历史，后面跟 N 轮对话。
    private func makeCommandDeniedHistory(roundsAfter: Int) -> [Message] {
        var messages: [Message] = []

        messages.append(TestFixtures.makeMessage(
            role: .system,
            content: "Command denied",
            systemMessageType: .commandDenied
        ))

        for _ in 0..<roundsAfter {
            messages.append(TestFixtures.makeMessage(role: .user, content: "next"))
            messages.append(TestFixtures.makeMessage(role: .assistant, content: "ok"))
        }

        return messages
    }

    /// 从 build 结果中找到指定 tool_call_id 的 tool response content。
    private func toolResponseContent(in result: [[String: Any]], toolCallId: String) -> String? {
        result.first {
            ($0["role"] as? String) == "tool" && ($0["tool_call_id"] as? String) == toolCallId
        }?["content"] as? String
    }

    // MARK: - 成功输出衰减

    @Test("成功 tool output 在 5 轮内不衰减")
    func successfulToolOutput_notDecayedWithin5Rounds() {
        let history = makeHistory(
            targetToolOutput: "total 42\ndrwxr-xr-x 2 root root 4096 Jan 1 00:00 .",
            roundsAfter: 5
        )
        let result = MessageBuilder.build(from: history)

        // 找到目标 tool response（第一个 tool role 消息）
        let firstToolResponse = result.first { ($0["role"] as? String) == "tool" }
        let content = firstToolResponse?["content"] as? String ?? ""

        #expect(content.contains("total 42"))
        #expect(!content.contains("output omitted"))
    }

    @Test("成功 tool output 超过 5 轮后衰减")
    func successfulToolOutput_decayedAfter5Rounds() {
        let history = makeHistory(
            targetToolName: "glob",
            targetToolOutput: "total 42\ndrwxr-xr-x 2 root root 4096 Jan 1 00:00 .",
            roundsAfter: 6
        )
        let result = MessageBuilder.build(from: history)

        let firstToolResponse = result.first { ($0["role"] as? String) == "tool" }
        let content = firstToolResponse?["content"] as? String ?? ""

        #expect(content == "[Tool: glob] executed successfully (output omitted)")
    }

    // MARK: - 失败输出衰减

    @Test("失败 tool output 超过 3 轮后衰减")
    func failedToolOutput_decayedAfter3Rounds() {
        let history = makeHistory(
            targetToolName: "execute_ssh_command",
            targetToolOutput: "Error: connection refused\nRetry later",
            roundsAfter: 4
        )
        let result = MessageBuilder.build(from: history)

        let firstToolResponse = result.first { ($0["role"] as? String) == "tool" }
        let content = firstToolResponse?["content"] as? String ?? ""

        #expect(content == "[Tool: execute_ssh_command] failed: Error: connection refused")
    }

    @Test("失败 tool output 在 3 轮内不衰减")
    func failedToolOutput_notDecayedAtThreshold() {
        let history = makeHistory(
            targetToolOutput: "Error: permission denied",
            roundsAfter: 3
        )
        let result = MessageBuilder.build(from: history)

        let firstToolResponse = result.first { ($0["role"] as? String) == "tool" }
        let content = firstToolResponse?["content"] as? String ?? ""

        #expect(content == "Error: permission denied")
        #expect(!content.contains("failed:"))
    }

    // MARK: - commandDenied 衰减

    @Test("commandDenied 超过 2 轮后移除")
    func commandDenied_removedAfter2Rounds() {
        let history = makeCommandDeniedHistory(roundsAfter: 3)
        let result = MessageBuilder.build(from: history)

        // commandDenied 应被移除，不应出现 "Command denied" 相关内容
        let hasCommandDenied = result.contains {
            ($0["content"] as? String)?.contains("denied") == true
        }
        #expect(!hasCommandDenied)
    }

    @Test("commandDenied 在 2 轮内保留")
    func commandDenied_keptWithin2Rounds() {
        let history = makeCommandDeniedHistory(roundsAfter: 2)
        let result = MessageBuilder.build(from: history)

        // commandDenied 应保留
        let hasCommandDenied = result.contains {
            ($0["content"] as? String)?.contains("denied") == true
        }
        #expect(hasCommandDenied)
    }
}
