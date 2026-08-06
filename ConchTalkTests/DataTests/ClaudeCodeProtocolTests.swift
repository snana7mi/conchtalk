/// 文件说明：ClaudeCodeProtocolTests，验证 Claude Code NDJSON 消息类型的编解码。

import Testing
import Foundation
@testable import ConchTalk

@Suite("ClaudeCodeProtocol")
struct ClaudeCodeProtocolTests {

    @Test("解码 system init 消息")
    func decodeSystemInit() throws {
        let json = """
        {"type":"system","subtype":"init","session_id":"abc-123","tools":["Bash","Read"],"model":"claude-sonnet-4-6","cwd":"/tmp"}
        """
        let msg = try JSONDecoder().decode(ClaudeCodeMessage.self, from: json.data(using: .utf8)!)
        guard case .system(let init_msg) = msg else {
            Issue.record("Expected system message")
            return
        }
        #expect(init_msg.sessionId == "abc-123")
        #expect(init_msg.model == "claude-sonnet-4-6")
        #expect(init_msg.tools == ["Bash", "Read"])
        #expect(init_msg.isInit)
    }

    @Test("system hook_started 消息 isInit 为 false")
    func decodeSystemHookStarted() throws {
        let json = """
        {"type":"system","subtype":"hook_started","hook_id":"abc","session_id":"sess-1"}
        """
        let msg = try JSONDecoder().decode(ClaudeCodeMessage.self, from: json.data(using: .utf8)!)
        guard case .system(let sysMsg) = msg else {
            Issue.record("Expected system message")
            return
        }
        #expect(!sysMsg.isInit)
        #expect(sysMsg.sessionId == "sess-1")
    }

    @Test("解码 assistant 消息（含 text + thinking + tool_use）")
    func decodeAssistantMessage() throws {
        let json = """
        {"type":"assistant","session_id":"abc","message":{"role":"assistant","content":[{"type":"thinking","thinking":"Let me think..."},{"type":"text","text":"Hello!"},{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"ls"}}],"usage":{"input_tokens":100,"output_tokens":50}}}
        """
        let msg = try JSONDecoder().decode(ClaudeCodeMessage.self, from: json.data(using: .utf8)!)
        guard case .assistant(let assistantMsg) = msg else {
            Issue.record("Expected assistant message")
            return
        }
        #expect(assistantMsg.message.content.count == 3)
    }

    @Test("解码 result 消息（成功）")
    func decodeResultSuccess() throws {
        let json = """
        {"type":"result","subtype":"success","session_id":"abc","result":"Done","total_cost_usd":0.01,"usage":{"input_tokens":200,"output_tokens":100}}
        """
        let msg = try JSONDecoder().decode(ClaudeCodeMessage.self, from: json.data(using: .utf8)!)
        guard case .result(let result) = msg else {
            Issue.record("Expected result message")
            return
        }
        #expect(result.subtype == "success")
        #expect(result.totalCostUsd == 0.01)
    }

    @Test("解码 control_request（权限请求）")
    func decodeControlRequest() throws {
        let json = """
        {"type":"control_request","request_id":"req_1","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"rm -rf /tmp/test"},"title":"Claude wants to run: rm -rf /tmp/test"}}
        """
        let msg = try JSONDecoder().decode(ClaudeCodeMessage.self, from: json.data(using: .utf8)!)
        guard case .controlRequest(let req) = msg else {
            Issue.record("Expected control_request message")
            return
        }
        #expect(req.requestId == "req_1")
        #expect(req.request.toolName == "Bash")
    }

    @Test("解码 keep_alive 消息")
    func decodeKeepAlive() throws {
        let json = """
        {"type":"keep_alive"}
        """
        let msg = try JSONDecoder().decode(ClaudeCodeMessage.self, from: json.data(using: .utf8)!)
        guard case .keepAlive = msg else {
            Issue.record("Expected keep_alive message")
            return
        }
    }

    @Test("编码 user prompt 消息")
    func encodeUserPrompt() throws {
        let prompt = ClaudeCodeUserMessage(text: "Hello world")
        let data = try JSONEncoder().encode(prompt)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(json["type"] as? String == "user")
    }

    @Test("编码 control_response（allow）")
    func encodeControlResponseAllow() throws {
        let response = ClaudeCodeControlResponse.allow(requestId: "req_1")
        let data = try JSONEncoder().encode(response)
        let json = String(data: data, encoding: .utf8)!
        #expect(json.contains("allow"))
        #expect(json.contains("req_1"))
    }

    @Test("编码 control_response（deny）")
    func encodeControlResponseDeny() throws {
        let response = ClaudeCodeControlResponse.deny(requestId: "req_1", message: "User denied")
        let data = try JSONEncoder().encode(response)
        let json = String(data: data, encoding: .utf8)!
        #expect(json.contains("deny"))
        #expect(json.contains("User denied"))
    }
}
