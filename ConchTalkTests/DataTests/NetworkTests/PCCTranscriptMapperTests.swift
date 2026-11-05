/// 文件说明：PCCTranscriptMapperTests，验证 OpenAI 消息 → Transcript、工具 schema 转换与 PCC 错误映射。
import Testing
@testable import ConchTalk
import Foundation
import FoundationModels

@Suite("PCC mapping")
struct PCCTranscriptMapperTests {

    @Test("历史消息映射：用户、助手文本、工具调用与工具输出")
    func mapsHistory() throws {
        guard #available(iOS 27.0, macOS 27.0, *) else { return }
        let messages: [[String: Any]] = [
            ["role": "system", "content": "ignored here"],
            ["role": "user", "content": "check disk"],
            [
                "role": "assistant",
                "content": NSNull(),
                "tool_calls": [[
                    "id": "call_1",
                    "type": "function",
                    "function": ["name": "execute_ssh_command", "arguments": #"{"command":"df -h","explanation":"Check disk"}"#],
                ]],
            ],
            ["role": "tool", "tool_call_id": "call_1", "content": "/dev/sda1 50%"],
            ["role": "assistant", "content": "Disk is half full."],
        ]
        let entries = PCCTranscriptMapper.historyEntries(from: messages)
        #expect(entries.count == 4)

        guard case .prompt(let prompt) = entries[0], case .text(let promptText) = prompt.segments.first else {
            Issue.record("first entry should be a prompt"); return
        }
        #expect(promptText.content == "check disk")

        let calls = PCCTranscriptMapper.lastToolCalls(in: entries)
        #expect(calls.map(\.id) == ["call_1"])
        #expect(calls.first?.toolName == "execute_ssh_command")

        guard case .toolOutput(let output) = entries[2] else { Issue.record("expected tool output"); return }
        #expect(output.id == "call_1")
        #expect(output.toolName == "execute_ssh_command")

        guard case .response = entries[3] else { Issue.record("expected response"); return }
    }

    @Test("模型工具调用转换为应用 ToolCall，保留参数与说明")
    func convertsToolCalls() throws {
        guard #available(iOS 27.0, macOS 27.0, *) else { return }
        let arguments = try GeneratedContent(json: #"{"command":"uptime","explanation":"Check load"}"#)
        let calls = PCCTranscriptMapper.toolCalls(
            from: [Transcript.ToolCall(id: "c1", toolName: "execute_ssh_command", arguments: arguments)],
            responseID: "r1"
        )
        let call = try #require(calls.first)
        #expect(call.id == "c1")
        #expect(call.explanation == "Check load")
        #expect(call.responseID == "r1")
        #expect(try call.decodedArguments()["command"] as? String == "uptime")
    }

    @Test("工具 JSON Schema 可转换为 GenerationSchema")
    func convertsSchemas() throws {
        guard #available(iOS 27.0, macOS 27.0, *) else { return }
        let definitions: [[String: Any]] = [[
            "type": "function",
            "function": [
                "name": "execute_ssh_command",
                "description": "Run a command",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "command": ["type": "string", "description": "Shell command"],
                        "timeout": ["type": "integer"],
                        "mode": ["type": "string", "enum": ["read", "write"]],
                        "paths": ["type": "array", "items": ["type": "string"]],
                        "nested": ["type": "object", "properties": ["flag": ["type": ["boolean", "null"]]]],
                    ],
                    "required": ["command"],
                ] as [String: Any],
            ] as [String: Any],
        ]]
        let proxies = PCCToolProxy.proxies(fromOpenAIDefinitions: definitions)
        #expect(proxies.map(\.name) == ["execute_ssh_command"])
        #expect(PCCSchemaConverter.primaryType(of: ["type": ["null", "number"]]) == "number")
    }

    @Test("PCC 错误映射与推理级别映射")
    func mapsErrorsAndReasoning() {
        guard #available(iOS 27.0, macOS 27.0, *) else { return }
        let reset = Date(timeIntervalSince1970: 1_800_000_000)
        let quota = PrivateCloudComputeLanguageModel.Error.quotaLimitReached(.init(resetDate: reset, debugDescription: "quota"))
        #expect(PCCAIService.failure(from: quota) == .quotaLimitReached(resetDate: reset))
        let network = PrivateCloudComputeLanguageModel.Error.networkFailure(.init(debugDescription: "net"))
        #expect(PCCAIService.failure(from: network) == .networkFailure)
        #expect(PCCAIService.failure(from: AIServiceError.invalidResponse) == nil)
        #expect(PCCAIService.failure(for: .deviceNotEligible) == .deviceNotEligible)

        #expect(PCCAIService.reasoningLevel(for: .modelDefault) == nil)
        #expect(PCCAIService.reasoningLevel(for: .high) == .deep)
    }

    @Test("流式快照差分")
    func streamDiff() {
        #expect(PCCStreamDiff.delta(previous: "", current: "Hel") == "Hel")
        #expect(PCCStreamDiff.delta(previous: "Hel", current: "Hello") == "lo")
        #expect(PCCStreamDiff.delta(previous: "Hello", current: "Hello") == nil)
        #expect(PCCStreamDiff.delta(previous: "Hello", current: "Help") == nil)
    }
}
