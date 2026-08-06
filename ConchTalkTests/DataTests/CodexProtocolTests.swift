/// 文件说明：CodexProtocolTests，验证 Codex JSON-RPC 消息类型的编解码。

import Testing
import Foundation
@testable import ConchTalk

@Suite("CodexProtocol")
struct CodexProtocolTests {

    @Test("解码 RPC 响应（initialize）")
    func decodeInitializeResponse() throws {
        let json = """
        {"jsonrpc":"2.0","id":1,"result":{"serverInfo":{"name":"codex-app-server","version":"0.116.0"}}}
        """
        let msg = try JSONDecoder().decode(CodexRPCMessage.self, from: json.data(using: .utf8)!)
        guard case .response(let resp) = msg else {
            Issue.record("Expected response")
            return
        }
        #expect(resp.id == 1)
    }

    @Test("解码 notification（item/agentMessage/delta）")
    func decodeAgentMessageDelta() throws {
        let json = """
        {"method":"item/agentMessage/delta","params":{"threadId":"t1","turnId":"turn1","itemId":"msg1","delta":"hello "}}
        """
        let msg = try JSONDecoder().decode(CodexRPCMessage.self, from: json.data(using: .utf8)!)
        guard case .notification(let notif) = msg else {
            Issue.record("Expected notification")
            return
        }
        #expect(notif.method == "item/agentMessage/delta")
    }

    @Test("解码 item/started type=agentMessage")
    func decodeItemStartedAgentMessage() throws {
        let json = """
        {"method":"item/started","params":{"item":{"type":"agentMessage","id":"msg1","text":"","phase":"final_answer"},"threadId":"t1","turnId":"turn1"}}
        """
        let msg = try JSONDecoder().decode(CodexRPCMessage.self, from: json.data(using: .utf8)!)
        guard case .notification(let notif) = msg else {
            Issue.record("Expected notification")
            return
        }
        #expect(notif.method == "item/started")
        let item = try notif.decodeItemParams()
        #expect(item?.type == "agentMessage")
        #expect(item?.phase == "final_answer")
    }

    @Test("解码 item/started type=commandExecution")
    func decodeItemStartedCommand() throws {
        let json = """
        {"method":"item/started","params":{"item":{"type":"commandExecution","id":"cmd1","command":"ls /tmp"},"threadId":"t1","turnId":"turn1"}}
        """
        let msg = try JSONDecoder().decode(CodexRPCMessage.self, from: json.data(using: .utf8)!)
        guard case .notification(let notif) = msg else {
            Issue.record("Expected notification")
            return
        }
        let item = try notif.decodeItemParams()
        #expect(item?.type == "commandExecution")
        #expect(item?.command == "ls /tmp")
    }

    @Test("解码 token usage 通知")
    func decodeTokenUsage() throws {
        let json = """
        {"method":"thread/tokenUsage/updated","params":{"threadId":"t1","turnId":"turn1","tokenUsage":{"total":{"totalTokens":100,"inputTokens":80,"outputTokens":20},"last":{"totalTokens":100,"inputTokens":80,"outputTokens":20}}}}
        """
        let msg = try JSONDecoder().decode(CodexRPCMessage.self, from: json.data(using: .utf8)!)
        guard case .notification = msg else {
            Issue.record("Expected notification")
            return
        }
    }

    @Test("编码 initialize RPC 请求")
    func encodeInitializeRequest() throws {
        let req = CodexRPCRequest.initialize(id: 1)
        let data = try JSONEncoder().encode(req)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(json["jsonrpc"] as? String == "2.0")
        #expect(json["id"] as? Int == 1)
        #expect(json["method"] as? String == "initialize")
    }

    @Test("编码 turn/start 请求")
    func encodeTurnStartRequest() throws {
        let req = CodexRPCRequest.turnStart(id: 5, threadId: "abc", text: "hello")
        let data = try JSONEncoder().encode(req)
        let parsed = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(parsed["method"] as? String == "turn/start")
        #expect(parsed["id"] as? Int == 5)
        let params = parsed["params"] as? [String: Any]
        #expect(params?["threadId"] as? String == "abc")
        #expect(json(data).contains("hello"))
    }

    /// 辅助方法：将 Data 转为 JSON 字符串。
    private func json(_ data: Data) -> String {
        String(data: data, encoding: .utf8) ?? ""
    }
}
