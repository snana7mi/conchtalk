/// 文件说明：ToolCallTests，测试 ToolCall 领域实体的参数解码、编解码及错误处理行为。
import Testing
@testable import ConchTalk
import Foundation

@Suite("ToolCall Entity")
struct ToolCallTests {

    // MARK: - 参数解码

    @Test("decodedArguments returns expected dictionary")
    func decodedArgumentsNormalDecode() throws {
        let toolCall = TestFixtures.makeToolCall(
            arguments: ["command": "ls -la", "timeout": 30]
        )
        let args = try toolCall.decodedArguments()
        #expect(args["command"] as? String == "ls -la")
        #expect(args["timeout"] as? Int == 30)
    }

    // MARK: - Codable

    @Test("Codable round-trip preserves all fields")
    func codableRoundTrip() throws {
        let original = TestFixtures.makeToolCall(
            id: "call_abc123",
            toolName: "read_file",
            arguments: ["path": "/etc/hosts"],
            explanation: "Read the hosts file"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ToolCall.self, from: data)
        #expect(decoded.id == original.id)
        #expect(decoded.toolName == original.toolName)
        #expect(decoded.explanation == original.explanation)
        #expect(decoded.argumentsJSON == original.argumentsJSON)
    }

    // MARK: - 错误处理

    @Test("decodedArguments throws on invalid JSON")
    func decodedArgumentsThrowsOnInvalidJSON() {
        let invalidJSON = Data("not valid json {{{".utf8)
        let toolCall = ToolCall(
            id: "call_bad",
            toolName: "execute_ssh_command",
            argumentsJSON: invalidJSON,
            explanation: "This should fail"
        )
        #expect(throws: (any Error).self) {
            try toolCall.decodedArguments()
        }
    }
}
