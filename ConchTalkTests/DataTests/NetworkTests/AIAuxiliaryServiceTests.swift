/// 文件说明：AIAuxiliaryServiceTests，验证非流式 AI 请求辅助逻辑。
import Testing
@testable import ConchTalk

@Suite("AIAuxiliaryService")
struct AIAuxiliaryServiceTests {

    @Test("parseMemorySummary 正常 JSON")
    func parseNormal() {
        let json = """
        {"conversation": "task A done", "server": "Ubuntu 22.04", "global": "prefers Chinese"}
        """
        let result = AIAuxiliaryService.parseMemorySummary(from: json)
        #expect(result.conversationMemory == "task A done")
        #expect(result.serverMemory == "Ubuntu 22.04")
        #expect(result.globalMemory == "prefers Chinese")
    }

    @Test("parseMemorySummary 处理 null")
    func parseNull() {
        let json = """
        {"conversation": null, "server": "Ubuntu", "global": null}
        """
        let result = AIAuxiliaryService.parseMemorySummary(from: json)
        #expect(result.conversationMemory == nil)
        #expect(result.serverMemory == "Ubuntu")
    }

    @Test("parseMemorySummary 容忍 markdown 包裹")
    func parseMarkdown() {
        let json = "```json\n{\"conversation\": \"test\", \"server\": null, \"global\": null}\n```"
        let result = AIAuxiliaryService.parseMemorySummary(from: json)
        #expect(result.conversationMemory == "test")
    }

    @Test("parseMemorySummary 无效返回全 nil")
    func parseInvalid() {
        let result = AIAuxiliaryService.parseMemorySummary(from: "not json")
        #expect(result.conversationMemory == nil)
        #expect(result.serverMemory == nil)
        #expect(result.globalMemory == nil)
    }

    @Test("buildExistingMemoryBlock 有内容")
    func blockWithContent() {
        let block = AIAuxiliaryService.buildExistingMemoryBlock(
            conversation: "session notes", server: "Ubuntu 22.04", global: nil
        )
        #expect(block.contains("session notes"))
        #expect(block.contains("Ubuntu 22.04"))
    }

    @Test("buildExistingMemoryBlock 全空")
    func blockEmpty() {
        let block = AIAuxiliaryService.buildExistingMemoryBlock(conversation: nil, server: nil, global: nil)
        #expect(block.contains("No existing memories"))
    }
}
