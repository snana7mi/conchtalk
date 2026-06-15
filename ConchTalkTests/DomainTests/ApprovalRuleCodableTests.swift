/// 文件说明：ApprovalRuleCodableTests，验证规则与匹配器的 Codable 往返。
import Testing
import Foundation
@testable import ConchTalk

@Suite("ApprovalRule")
struct ApprovalRuleCodableTests {
    @Test("commandPrefix matcher 往返")
    func commandMatcherRoundTrip() throws {
        let m = ApprovalMatcher.commandPrefix(tokens: ["git", "-C", "/srv/app", "pull"])
        let data = try JSONEncoder().encode(m)
        let back = try JSONDecoder().decode(ApprovalMatcher.self, from: data)
        #expect(back == m)
    }

    @Test("pathPrefix matcher 往返")
    func pathMatcherRoundTrip() throws {
        let m = ApprovalMatcher.pathPrefix(prefix: "/etc/nginx", recursive: true)
        let data = try JSONEncoder().encode(m)
        #expect(try JSONDecoder().decode(ApprovalMatcher.self, from: data) == m)
    }

    @Test("rule 往返")
    func ruleRoundTrip() throws {
        let id = UUID(), sid = UUID(), now = Date()
        let r = ApprovalRule(id: id, serverID: sid, toolName: "write_file",
                             matcher: .pathPrefix(prefix: "/srv", recursive: true),
                             displayLabel: "写入 /srv 下", createdAt: now, modifiedAt: now)
        let data = try JSONEncoder().encode(r)
        #expect(try JSONDecoder().decode(ApprovalRule.self, from: data) == r)
    }
}
