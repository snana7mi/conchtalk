/// 文件说明：RetainServiceTests，覆盖 RetainService.parseRetainResponse 的 JSON 解析逻辑。
import Testing
@testable import ConchTalk
import Foundation

@Suite("RetainService")
struct RetainServiceTests {

    @Test("解析有效 JSON：提取 facts 和 coreMemoryUpdate")
    func parseValidJSON() {
        let json = """
        {"facts": [{"content": "nginx is running on port 80", "tags": ["nginx", "web"], "entities": ["nginx"]}, {"content": "app is deployed at /var/www/app", "tags": ["deployment"], "entities": ["/var/www/app"]}], "coreMemoryUpdate": "Server runs nginx on port 80 with app at /var/www/app"}
        """
        let result = RetainService.parseRetainResponse(json)
        #expect(result.facts.count == 2)
        #expect(result.facts[0].content == "nginx is running on port 80")
        #expect(result.facts[0].tags == ["nginx", "web"])
        #expect(result.facts[0].entities == ["nginx"])
        #expect(result.facts[1].content == "app is deployed at /var/www/app")
        #expect(result.coreMemoryUpdate == "Server runs nginx on port 80 with app at /var/www/app")
    }

    @Test("解析空 facts 数组")
    func parseEmptyFacts() {
        let json = """
        {"facts": [], "coreMemoryUpdate": null}
        """
        let result = RetainService.parseRetainResponse(json)
        #expect(result.facts.isEmpty)
        #expect(result.coreMemoryUpdate == nil)
    }

    @Test("coreMemoryUpdate 为 null 时返回 nil")
    func parseNullCoreMemoryUpdate() {
        let json = """
        {"facts": [{"content": "Redis is installed", "tags": ["redis"], "entities": ["redis"]}], "coreMemoryUpdate": null}
        """
        let result = RetainService.parseRetainResponse(json)
        #expect(result.facts.count == 1)
        #expect(result.coreMemoryUpdate == nil)
    }

    @Test("AI 回复包含前缀文本时仍能解析")
    func parseWithPrefixText() {
        let json = """
        Here are the extracted facts:
        {"facts": [{"content": "Docker is running", "tags": ["docker"], "entities": ["docker"]}], "coreMemoryUpdate": null}
        """
        let result = RetainService.parseRetainResponse(json)
        #expect(result.facts.count == 1)
        #expect(result.facts[0].content == "Docker is running")
    }

    @Test("无效 JSON 返回空结果")
    func parseInvalidJSON() {
        let result = RetainService.parseRetainResponse("not json at all")
        #expect(result.facts.isEmpty)
        #expect(result.coreMemoryUpdate == nil)
    }

    @Test("缺少 entities 字段时默认为空数组")
    func parseMissingEntities() {
        let json = """
        {"facts": [{"content": "Server is Ubuntu 22.04", "tags": ["os"]}], "coreMemoryUpdate": null}
        """
        let result = RetainService.parseRetainResponse(json)
        #expect(result.facts.count == 1)
        #expect(result.facts[0].entities.isEmpty)
    }
}
