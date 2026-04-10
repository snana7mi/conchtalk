/// 文件说明：RelayMessageTests，测试 relay 消息解析。
import XCTest
@testable import ConchTalk

final class RelayMessageTests: XCTestCase {

    func testParseAssistantText() {
        let json = #"{"type": "assistant_text", "delta": "Hello"}"#
        let event = RelayMessage.parse(from: json.data(using: .utf8)!)
        if case .assistantText(let delta) = event {
            XCTAssertEqual(delta, "Hello")
        } else {
            XCTFail("Expected assistantText, got \(String(describing: event))")
        }
    }

    func testParseToolCall() {
        let json = #"{"type": "tool_call", "id": "tc-1", "tool": "execute_command", "args": {"command": "ls"}}"#
        let event = RelayMessage.parse(from: json.data(using: .utf8)!)
        if case .toolCall(let id, let tool, let args) = event {
            XCTAssertEqual(id, "tc-1")
            XCTAssertEqual(tool, "execute_command")
            XCTAssertEqual(args["command"] as? String, "ls")
        } else {
            XCTFail("Expected toolCall")
        }
    }

    func testParseToolProgress() {
        let json = #"{"type": "tool_progress", "id": "tc-1", "stream": "stdout", "data": "output line\n"}"#
        let event = RelayMessage.parse(from: json.data(using: .utf8)!)
        if case .toolProgress(let id, let stream, let data) = event {
            XCTAssertEqual(id, "tc-1")
            XCTAssertEqual(stream, "stdout")
            XCTAssertEqual(data, "output line\n")
        } else {
            XCTFail("Expected toolProgress")
        }
    }

    func testParseToolResult() {
        let json = #"{"type": "tool_result", "id": "tc-1", "exit_code": 0}"#
        let event = RelayMessage.parse(from: json.data(using: .utf8)!)
        if case .toolResult(let id, let exitCode) = event {
            XCTAssertEqual(id, "tc-1")
            XCTAssertEqual(exitCode, 0)
        } else {
            XCTFail("Expected toolResult")
        }
    }

    func testParseApprovalRequest() {
        let json = #"{"type": "approval_request", "id": "tc-2", "tool": "write_file", "args": {"path": "/tmp/x"}, "explanation": "Writing file"}"#
        let event = RelayMessage.parse(from: json.data(using: .utf8)!)
        if case .approvalRequest(let id, let tool, _, let explanation) = event {
            XCTAssertEqual(id, "tc-2")
            XCTAssertEqual(tool, "write_file")
            XCTAssertEqual(explanation, "Writing file")
        } else {
            XCTFail("Expected approvalRequest")
        }
    }

    func testParseDone() {
        let json = #"{"type": "done"}"#
        let event = RelayMessage.parse(from: json.data(using: .utf8)!)
        if case .done = event {
            // pass
        } else {
            XCTFail("Expected done")
        }
    }

    func testParseError() {
        let json = #"{"type": "error", "message": "Budget exceeded"}"#
        let event = RelayMessage.parse(from: json.data(using: .utf8)!)
        if case .error(let message) = event {
            XCTAssertEqual(message, "Budget exceeded")
        } else {
            XCTFail("Expected error")
        }
    }

    func testParseDaemonStatusOnline() {
        let json = #"{"type": "status", "daemon": "online"}"#
        let event = RelayMessage.parse(from: json.data(using: .utf8)!)
        if case .daemonStatus(let online) = event {
            XCTAssertTrue(online)
        } else {
            XCTFail("Expected daemonStatus")
        }
    }

    func testParseDaemonStatusOffline() {
        let json = #"{"type": "status", "daemon": "offline"}"#
        let event = RelayMessage.parse(from: json.data(using: .utf8)!)
        if case .daemonStatus(let online) = event {
            XCTAssertFalse(online)
        } else {
            XCTFail("Expected daemonStatus")
        }
    }

    func testParseACPStarted() {
        let json = #"{"type": "acp_started", "session_id": "sess-1"}"#
        let event = RelayMessage.parse(from: json.data(using: .utf8)!)
        if case .acpStarted(let sessionID) = event {
            XCTAssertEqual(sessionID, "sess-1")
        } else {
            XCTFail("Expected acpStarted, got \(String(describing: event))")
        }
    }

    func testParseACPData() {
        let json = #"{"type": "acp_data", "session_id": "sess-1", "stream": "stdout", "data": "{\"jsonrpc\":\"2.0\"}\n"}"#
        let event = RelayMessage.parse(from: json.data(using: .utf8)!)
        if case .acpData(let sessionID, let stream, let data) = event {
            XCTAssertEqual(sessionID, "sess-1")
            XCTAssertEqual(stream, "stdout")
            XCTAssertTrue(data.contains("jsonrpc"))
        } else {
            XCTFail("Expected acpData, got \(String(describing: event))")
        }
    }

    func testParseACPClosed() {
        let json = #"{"type": "acp_closed", "session_id": "sess-1"}"#
        let event = RelayMessage.parse(from: json.data(using: .utf8)!)
        if case .acpClosed(let sessionID) = event {
            XCTAssertEqual(sessionID, "sess-1")
        } else {
            XCTFail("Expected acpClosed, got \(String(describing: event))")
        }
    }

    func testParseACPError() {
        let json = #"{"type": "acp_error", "session_id": "sess-1", "error": "session not found"}"#
        let event = RelayMessage.parse(from: json.data(using: .utf8)!)
        if case .acpError(let sessionID, let error) = event {
            XCTAssertEqual(sessionID, "sess-1")
            XCTAssertEqual(error, "session not found")
        } else {
            XCTFail("Expected acpError, got \(String(describing: event))")
        }
    }

    func testParsePongReturnsNil() {
        let json = #"{"type": "pong"}"#
        let event = RelayMessage.parse(from: json.data(using: .utf8)!)
        XCTAssertNil(event)
    }

    func testParseUnknownTypeReturnsNil() {
        let json = #"{"type": "unknown_message"}"#
        let event = RelayMessage.parse(from: json.data(using: .utf8)!)
        XCTAssertNil(event)
    }

    func testParseInvalidJSONReturnsNil() {
        let event = RelayMessage.parse(from: "not json".data(using: .utf8)!)
        XCTAssertNil(event)
    }

    func testParseMissingTypeReturnsNil() {
        let json = #"{"id": "tc-1"}"#
        let event = RelayMessage.parse(from: json.data(using: .utf8)!)
        XCTAssertNil(event)
    }
}
