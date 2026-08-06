/// 文件说明：DirectAgentSessionRoutingTests，验证 DirectAgentSession 根据 AgentType 选择正确的 Connection。

import Testing
@testable import ConchTalk

@Suite("DirectAgentSession Routing")
struct DirectAgentSessionRoutingTests {
    @Test("Claude 类型路由到 claudeCode")
    func claudeRouting() {
        let connType = DirectAgentSession.connectionType(for: .claude)
        #expect(connType == .claudeCode)
    }

    @Test("Codex 类型路由到 codex")
    func codexRouting() {
        let connType = DirectAgentSession.connectionType(for: .codex)
        #expect(connType == .codex)
    }

    @Test("OpenCode 类型路由到 acp")
    func openCodeRouting() {
        let connType = DirectAgentSession.connectionType(for: .opencode)
        #expect(connType == .acp)
    }

    @Test("Gemini 类型路由到 acp")
    func geminiRouting() {
        let connType = DirectAgentSession.connectionType(for: .gemini)
        #expect(connType == .acp)
    }

    @Test("所有非 Claude/Codex 类型都路由到 acp")
    func allOtherTypesRouteToACP() {
        let nonNativeTypes: [AgentType] = [.opencode, .gemini, .kimi, .openclaw, .qwen]
        for agentType in nonNativeTypes {
            #expect(DirectAgentSession.connectionType(for: agentType) == .acp)
        }
    }
}
