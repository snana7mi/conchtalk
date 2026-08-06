/// 文件说明：CodexConnectionTests，验证 Codex 通知到 SessionUpdate 的翻译。

import Testing
import Foundation
@testable import ConchTalk
@preconcurrency import ACPModel

@Suite("CodexConnection")
struct CodexConnectionTests {
    @Test("RPC 响应先到时后续等待仍可拿到结果")
    func bufferedResponseBufferPreservesEarlyResponse() async throws {
        let buffer = BufferedResponseBuffer<CodexRPCResponse>()
        let response = CodexRPCResponse(id: 7, result: .object([:]), error: nil)
        await buffer.succeed(response)

        let received = try await buffer.wait()
        #expect(received.id == 7)
    }

    @Test("失败信号先到时后续等待仍会抛错")
    func bufferedCompletionSignalPreservesEarlyFailure() async {
        let signal = BufferedCompletionSignal()
        await signal.fail(ACPConnectionError.disconnected)

        do {
            try await signal.wait()
            Issue.record("Expected ACPConnectionError.disconnected")
        } catch {
            guard case ACPConnectionError.disconnected = error else {
                Issue.record("Expected ACPConnectionError.disconnected, got \(error)")
                return
            }
        }
    }

    @Test("AgentConnectionInfo 可承载 Codex commands/modes/models 元数据")
    func infoCarriesCodexMetadata() {
        let info = AgentConnectionInfo(
            displayName: "Codex",
            models: ModelsInfo(
                currentModelId: "gpt-5-codex",
                availableModels: [ModelInfo(modelId: "gpt-5-codex", name: "GPT-5 Codex", description: nil)]
            ),
            modes: ModesInfo(
                currentModeId: "default",
                availableModes: [ModeInfo(id: "default", name: "Default")]
            ),
            configOptions: [],
            availableCommands: [AvailableCommand(name: "brainstorming", description: "Design first")]
        )
        #expect(info.models?.currentModelId == "gpt-5-codex")
        #expect(info.modes?.currentModeId == "default")
        #expect(info.availableCommands.map(\.name) == ["brainstorming"])
    }

    @Test("agentMessage item/started (final_answer) 翻译为 nil（文本通过 delta 传递）")
    func translateAgentMessageStart() throws {
        let item = CodexItem(type: "agentMessage", id: "msg1", text: "hello", phase: "final_answer",
                             command: nil, query: nil, aggregatedOutput: nil, content: nil)
        let update = CodexMessageTranslator.translateItemStarted(item)
        // final_answer item/started 不产生 update（文本通过 delta 传递）
        #expect(update == nil)
    }

    @Test("agentMessage delta 翻译为 agentMessageChunk")
    func translateDelta() {
        let update = CodexMessageTranslator.translateDelta("hello world")
        guard case .agentMessageChunk(let content) = update else {
            Issue.record("Expected agentMessageChunk")
            return
        }
        if case .text(let tc) = content {
            #expect(tc.text == "hello world")
        }
    }

    @Test("commandExecution item/started 翻译为 toolCall")
    func translateCommandExecution() {
        let item = CodexItem(type: "commandExecution", id: "cmd1", text: nil, phase: nil,
                             command: "ls /tmp", query: nil, aggregatedOutput: nil, content: nil)
        let update = CodexMessageTranslator.translateItemStarted(item)
        guard case .toolCall(let tc) = update else {
            Issue.record("Expected toolCall")
            return
        }
        #expect(tc.title == "ls /tmp")
        #expect(tc.status == .inProgress)
        #expect(tc.kind == .execute)
    }

    @Test("commandExecution item/completed 翻译为 toolCallUpdate")
    func translateCommandCompleted() {
        let item = CodexItem(type: "commandExecution", id: "cmd1", text: "exit code 0", phase: nil,
                             command: "ls /tmp", query: nil, aggregatedOutput: "file1\nfile2", content: nil)
        let update = CodexMessageTranslator.translateItemCompleted(item)
        guard case .toolCallUpdate(let details) = update else {
            Issue.record("Expected toolCallUpdate")
            return
        }
        #expect(details.status == .completed)
        #expect(details.toolCallId == "cmd1")
    }

    @Test("reasoning item/started 翻译为 nil（无文本内容）")
    func translateReasoning() {
        let item = CodexItem(type: "reasoning", id: "rs1", text: nil, phase: nil,
                             command: nil, query: nil, aggregatedOutput: nil, content: nil)
        let update = CodexMessageTranslator.translateItemStarted(item)
        // reasoning item/started 无文本内容，不产生 update
        #expect(update == nil)
    }

    @Test("commentary phase 翻译为 agentThoughtChunk")
    func translateCommentary() {
        let item = CodexItem(type: "agentMessage", id: "msg1", text: "thinking about it", phase: "commentary",
                             command: nil, query: nil, aggregatedOutput: nil, content: nil)
        let update = CodexMessageTranslator.translateItemCompleted(item)
        guard case .agentThoughtChunk = update else {
            Issue.record("Expected agentThoughtChunk")
            return
        }
    }

    @Test("fileChange item/started 翻译为 toolCall (edit)")
    func translateFileChangeStarted() {
        let item = CodexItem(type: "fileChange", id: "fc1", text: nil, phase: nil,
                             command: nil, query: nil, aggregatedOutput: nil, content: nil)
        let update = CodexMessageTranslator.translateItemStarted(item)
        guard case .toolCall(let tc) = update else {
            Issue.record("Expected toolCall")
            return
        }
        #expect(tc.kind == .edit)
        #expect(tc.status == .inProgress)
    }

    @Test("webSearch item/started 翻译为 toolCall (fetch)")
    func translateWebSearchStarted() {
        let item = CodexItem(type: "webSearch", id: "ws1", text: nil, phase: nil,
                             command: nil, query: "Swift concurrency", aggregatedOutput: nil, content: nil)
        let update = CodexMessageTranslator.translateItemStarted(item)
        guard case .toolCall(let tc) = update else {
            Issue.record("Expected toolCall")
            return
        }
        #expect(tc.kind == .fetch)
        #expect(tc.title == "Swift concurrency")
    }

    @Test("未知 item type 返回 nil")
    func translateUnknownType() {
        let item = CodexItem(type: "unknownType", id: "x1", text: nil, phase: nil,
                             command: nil, query: nil, aggregatedOutput: nil, content: nil)
        #expect(CodexMessageTranslator.translateItemStarted(item) == nil)
        #expect(CodexMessageTranslator.translateItemCompleted(item) == nil)
    }

    @Test("commentary phase item/started 有文本时产生 agentThoughtChunk")
    func translateCommentaryStarted() {
        let item = CodexItem(type: "agentMessage", id: "msg2", text: "let me think", phase: "commentary",
                             command: nil, query: nil, aggregatedOutput: nil, content: nil)
        let update = CodexMessageTranslator.translateItemStarted(item)
        guard case .agentThoughtChunk(let content) = update else {
            Issue.record("Expected agentThoughtChunk")
            return
        }
        if case .text(let tc) = content {
            #expect(tc.text == "let me think")
        }
    }
}
