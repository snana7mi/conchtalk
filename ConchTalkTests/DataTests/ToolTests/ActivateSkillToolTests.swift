/// 文件说明：ActivateSkillToolTests，验证 Skill 激活工具的稳定 JSON 输出合约。
import Testing
@testable import ConchTalk
import Foundation

@Suite("ActivateSkillTool")
struct ActivateSkillToolTests {
    private func makeTool() -> ActivateSkillTool {
        let skill = Skill(
            name: "health-check",
            description: "Check server health",
            compatibility: nil,
            metadata: ["displayName": "Health Check"],
            content: "# Health Check\n\nInspect CPU and memory.",
            directoryURL: nil
        )
        return ActivateSkillTool(skillRegistry: SkillRegistry(preloaded: [skill]))
    }

    @Test("激活成功返回内容与 UI 元数据")
    func activationReturnsJSONEnvelope() async throws {
        let result = try await makeTool().execute(
            arguments: ["skill_name": "health-check", "explanation": "matched"],
            sshClient: MockSSHClient()
        )
        let data = try #require(result.output.data(using: .utf8))
        let json = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        #expect(json["status"] as? String == "activated")
        #expect(json["skillName"] as? String == "health-check")
        #expect(json["displayName"] as? String == "Health Check")
        #expect((json["content"] as? String)?.contains("Inspect CPU") == true)
    }

    @Test("激活 JSON 可生成 skillLoaded 系统消息")
    func activationProducesSkillLoadedMessage() async throws {
        let result = try await makeTool().execute(
            arguments: ["skill_name": "health-check", "explanation": "matched"],
            sshClient: MockSSHClient()
        )

        let message = SpecialToolHandler.skillLoadedMessage(
            forToolName: "activate_skill",
            output: result.output
        )

        #expect(message?.role == .system)
        #expect(message?.systemMessageType == .skillLoaded)
        #expect(message?.content == "Health Check")
    }
}
