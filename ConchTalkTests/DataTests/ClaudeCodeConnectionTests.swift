/// 文件说明：ClaudeCodeConnectionTests，验证 Claude Code 消息到 SessionUpdate 的翻译。

import Testing
import Foundation
@testable import ConchTalk
@preconcurrency import ACPModel

final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func setTrue() {
        lock.lock()
        value = true
        lock.unlock()
    }

    func isTrue() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

@Suite("ClaudeCodeConnection")
struct ClaudeCodeConnectionTests {
    @Test("完成信号先到时后续等待仍会完成")
    func bufferedCompletionSignalPreservesEarlySuccess() async throws {
        let signal = BufferedCompletionSignal()
        await signal.succeed()
        try await signal.wait()
    }

    @Test("旧 turn 的迟到完成不会污染新等待")
    func lateCompletionDoesNotLeakAcrossTurns() async throws {
        let signal = BufferedCompletionSignal()
        let firstTurn = await signal.beginTurn()
        await signal.fail(CancellationError(), for: firstTurn)

        let secondTurn = await signal.beginTurn()
        await signal.succeed(for: firstTurn)
        let completed = LockedFlag()

        let waiter = Task {
            try await signal.wait(for: secondTurn)
            completed.setTrue()
        }

        try? await Task.sleep(for: .milliseconds(20))
        #expect(completed.isTrue() == false)

        await signal.succeed(for: secondTurn)
        try await waiter.value
        #expect(completed.isTrue())
    }

    @Test("AgentConnectionInfo 可承载 Claude commands 元数据")
    func infoCarriesClaudeCommandsMetadata() {
        let info = AgentConnectionInfo(
            displayName: "Claude Code",
            models: nil,
            modes: nil,
            configOptions: [],
            availableCommands: [AvailableCommand(name: "/cost", description: "Show usage")]
        )
        #expect(info.availableCommands.map(\.name) == ["/cost"])
    }

    @Test("assistant text content 翻译为 agentMessageChunk")
    func translateTextContent() {
        let block = ClaudeContentBlock.text("Hello world")
        let update = ClaudeCodeMessageTranslator.translateContentBlock(block)
        guard case .agentMessageChunk(let content) = update else {
            Issue.record("Expected agentMessageChunk")
            return
        }
        if case .text(let tc) = content {
            #expect(tc.text == "Hello world")
        }
    }

    @Test("assistant thinking content 翻译为 agentThoughtChunk")
    func translateThinkingContent() {
        let block = ClaudeContentBlock.thinking("Let me think...")
        let update = ClaudeCodeMessageTranslator.translateContentBlock(block)
        guard case .agentThoughtChunk(let content) = update else {
            Issue.record("Expected agentThoughtChunk")
            return
        }
        if case .text(let tc) = content {
            #expect(tc.text == "Let me think...")
        }
    }

    @Test("assistant tool_use content 翻译为 toolCall")
    func translateToolUse() {
        let block = ClaudeContentBlock.toolUse(id: "toolu_1", name: "Bash", input: ["command": .string("ls")])
        let update = ClaudeCodeMessageTranslator.translateContentBlock(block)
        guard case .toolCall(let tc) = update else {
            Issue.record("Expected toolCall")
            return
        }
        #expect(tc.kind == .execute)
        #expect(tc.status == .inProgress)
        #expect(tc.toolCallId == "toolu_1")
    }

    @Test("user tool_result 翻译为 toolCallUpdate")
    func translateToolResult() {
        let result = ClaudeToolResultContent(type: "tool_result", toolUseId: "toolu_1", content: "file1\nfile2")
        let update = ClaudeCodeMessageTranslator.translateToolResult(result)
        guard case .toolCallUpdate(let details) = update else {
            Issue.record("Expected toolCallUpdate")
            return
        }
        #expect(details.status == .completed)
        #expect(details.toolCallId == "toolu_1")
    }

    @Test("control_request 翻译为权限描述")
    func translateControlRequest() {
        let req = ClaudeControlRequest(
            requestId: "req_1",
            request: ClaudePermissionDetails(
                subtype: "can_use_tool",
                toolName: "Bash",
                input: ["command": .string("rm -rf /tmp")],
                title: "Run: rm -rf /tmp",
                description: nil
            )
        )
        let desc = ClaudeCodeMessageTranslator.permissionDescription(from: req)
        #expect(desc.contains("Bash") || desc.contains("rm -rf /tmp"))
    }

    @Test("control_request 无 title 时用 toolName + input 构造描述")
    func translateControlRequestNoTitle() {
        let req = ClaudeControlRequest(
            requestId: "req_2",
            request: ClaudePermissionDetails(
                subtype: "can_use_tool",
                toolName: "Bash",
                input: ["command": .string("echo hello")],
                title: nil,
                description: nil
            )
        )
        let desc = ClaudeCodeMessageTranslator.permissionDescription(from: req)
        #expect(desc.contains("Bash"))
        #expect(desc.contains("echo hello"))
    }

    @Test("Read 工具映射为 .read kind")
    func translateReadToolKind() {
        let block = ClaudeContentBlock.toolUse(id: "toolu_2", name: "Read", input: ["file_path": .string("/etc/hosts")])
        let update = ClaudeCodeMessageTranslator.translateContentBlock(block)
        guard case .toolCall(let tc) = update else {
            Issue.record("Expected toolCall")
            return
        }
        #expect(tc.kind == .read)
    }

    @Test("Edit 工具映射为 .edit kind")
    func translateEditToolKind() {
        let block = ClaudeContentBlock.toolUse(id: "toolu_3", name: "Edit", input: ["file_path": .string("main.swift")])
        let update = ClaudeCodeMessageTranslator.translateContentBlock(block)
        guard case .toolCall(let tc) = update else {
            Issue.record("Expected toolCall")
            return
        }
        #expect(tc.kind == .edit)
    }

    @Test("tool_result 无 toolUseId 时使用 unknown")
    func translateToolResultNoId() {
        let result = ClaudeToolResultContent(type: "tool_result", toolUseId: nil, content: "output")
        let update = ClaudeCodeMessageTranslator.translateToolResult(result)
        guard case .toolCallUpdate(let details) = update else {
            Issue.record("Expected toolCallUpdate")
            return
        }
        #expect(details.toolCallId == "unknown")
    }
}
