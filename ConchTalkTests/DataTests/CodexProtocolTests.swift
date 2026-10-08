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

    // MARK: - 服务端请求（审批）

    @Test("同时有 id 和 method 的消息解码为服务端请求，而非通知")
    func decodeServerRequest() throws {
        let json = """
        {"id":8,"method":"item/commandExecution/requestApproval","params":{"threadId":"t1","turnId":"turn1","itemId":"cmd1","startedAtMs":1,"command":"rm -rf build","cwd":"/repo","reason":"needs write"}}
        """
        let msg = try JSONDecoder().decode(CodexRPCMessage.self, from: json.data(using: .utf8)!)
        guard case .request(let req) = msg else {
            Issue.record("Expected request")
            return
        }
        #expect(req.id == .int(8))
        #expect(req.method == "item/commandExecution/requestApproval")
        #expect(req.stringParam("command") == "rm -rf build")
    }

    @Test("字符串 request id 原样保留")
    func decodeServerRequestStringId() throws {
        let json = """
        {"id":"req-1","method":"item/fileChange/requestApproval","params":{"threadId":"t1","turnId":"turn1","itemId":"fc1","startedAtMs":1}}
        """
        let msg = try JSONDecoder().decode(CodexRPCMessage.self, from: json.data(using: .utf8)!)
        guard case .request(let req) = msg else {
            Issue.record("Expected request")
            return
        }
        #expect(req.id == .string("req-1"))
    }

    @Test("命令审批映射为权限请求，批准回复 accept、拒绝回复 decline")
    func commandApprovalRoundTrip() throws {
        let req = try decodeRequest("""
        {"id":8,"method":"item/commandExecution/requestApproval","params":{"threadId":"t1","turnId":"turn1","itemId":"cmd1","startedAtMs":1,"command":"make install","cwd":"/repo"}}
        """)
        let perm = try #require(CodexServerRequestBridge.permissionRequest(for: req))
        #expect(perm.tool == "commandExecution")
        #expect(perm.description.contains("make install"))
        #expect(perm.description.contains("/repo"))

        let accepted = try encodeObject(CodexServerRequestBridge.approvalResponse(for: req, approved: true))
        #expect(accepted["id"] as? Int == 8)
        #expect((accepted["result"] as? [String: Any])?["decision"] as? String == "accept")
        #expect(accepted["error"] == nil)

        let declined = try encodeObject(CodexServerRequestBridge.approvalResponse(for: req, approved: false))
        #expect((declined["result"] as? [String: Any])?["decision"] as? String == "decline")
    }

    @Test("文件修改审批映射为权限请求")
    func fileChangeApproval() throws {
        let req = try decodeRequest("""
        {"id":"x","method":"item/fileChange/requestApproval","params":{"threadId":"t1","turnId":"turn1","itemId":"fc1","startedAtMs":1,"grantRoot":"/etc"}}
        """)
        let perm = try #require(CodexServerRequestBridge.permissionRequest(for: req))
        #expect(perm.tool == "fileChange")
        #expect(perm.description.contains("/etc"))
        let response = try encodeObject(CodexServerRequestBridge.approvalResponse(for: req, approved: true))
        #expect(response["id"] as? String == "x")
    }

    @Test("不支持的服务端请求回复 JSON-RPC -32601，而不是静默忽略")
    func unsupportedRequestGetsError() throws {
        let req = try decodeRequest("""
        {"id":3,"method":"item/tool/call","params":{}}
        """)
        #expect(CodexServerRequestBridge.permissionRequest(for: req) == nil)
        let response = try encodeObject(CodexServerRequestBridge.defaultResponse(for: req))
        #expect(response["id"] as? Int == 3)
        #expect((response["error"] as? [String: Any])?["code"] as? Int == -32601)
        #expect(response["result"] == nil)
    }

    @Test("追加权限请求默认授予空权限集，MCP elicitation 默认 decline")
    func defaultResponsesForPermissionsAndElicitation() throws {
        let permReq = try decodeRequest("""
        {"id":4,"method":"item/permissions/requestApproval","params":{}}
        """)
        let perm = try encodeObject(CodexServerRequestBridge.defaultResponse(for: permReq))
        let permResult = try #require(perm["result"] as? [String: Any])
        #expect((permResult["permissions"] as? [String: Any])?.isEmpty == true)
        #expect(permResult["scope"] as? String == "turn")

        let elicitReq = try decodeRequest("""
        {"id":5,"method":"mcpServer/elicitation/request","params":{}}
        """)
        let elicit = try encodeObject(CodexServerRequestBridge.defaultResponse(for: elicitReq))
        #expect((elicit["result"] as? [String: Any])?["action"] as? String == "decline")
    }

    @Test("thread/start 显式设置 approvalPolicy=on-request")
    func threadStartSetsApprovalPolicy() throws {
        let data = try JSONEncoder().encode(CodexRPCRequest.threadStart(id: 2, cwd: "/repo"))
        let parsed = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let params = parsed["params"] as? [String: Any]
        #expect(params?["cwd"] as? String == "/repo")
        #expect(params?["approvalPolicy"] as? String == "on-request")
    }

    private func decodeRequest(_ json: String) throws -> CodexServerRequest {
        let msg = try JSONDecoder().decode(CodexRPCMessage.self, from: json.data(using: .utf8)!)
        guard case .request(let req) = msg else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Expected request"))
        }
        return req
    }

    private func encodeObject(_ response: CodexServerResponse) throws -> [String: Any] {
        let data = try JSONEncoder().encode(response)
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    /// 辅助方法：将 Data 转为 JSON 字符串。
    private func json(_ data: Data) -> String {
        String(data: data, encoding: .utf8) ?? ""
    }
}
