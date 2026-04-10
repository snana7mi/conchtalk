/// 文件说明：SystemPromptBuilderTests，验证 system prompt 组装逻辑。
import Foundation
import Testing
@testable import ConchTalk

@Suite("SystemPromptBuilder")
struct SystemPromptBuilderTests {

    @Test("包含当前助手身份描述和服务器名")
    func identityAndTone() {
        let prompt = SystemPromptBuilder.build(
            serverName: "我的服务器",
            serverContext: "",
            tools: [],
            permissionLevel: .standard,
            skillSummaries: ""
        )
        #expect(prompt.contains("我的服务器"))
        #expect(prompt.contains("calm, professional, and efficient"))
        #expect(prompt.contains("Tone & Style"))
    }

    @Test("空服务器名回退到 AI Assistant")
    func emptyServerNameFallback() {
        let prompt = SystemPromptBuilder.build(
            serverName: "",
            serverContext: "",
            tools: [],
            permissionLevel: .standard,
            skillSummaries: ""
        )
        #expect(prompt.contains("AI Assistant"))
    }

    @Test("包含服务器上下文")
    func serverContextInjected() {
        let prompt = SystemPromptBuilder.build(
            serverName: "S",
            serverContext: "Ubuntu 22.04 LTS",
            tools: [],
            permissionLevel: .standard,
            skillSummaries: ""
        )
        #expect(prompt.contains("Ubuntu 22.04 LTS"))
    }

    @Test("包含 Core Mandates 安全规则")
    func coreMandatesPresent() {
        let prompt = SystemPromptBuilder.build(
            serverName: "S",
            serverContext: "",
            tools: [],
            permissionLevel: .standard,
            skillSummaries: ""
        )
        #expect(prompt.contains("Core Mandates"))
        #expect(prompt.contains("NEVER execute destructive commands"))
    }

    @Test("strict 模式包含确认提示")
    func strictPermission() {
        let prompt = SystemPromptBuilder.build(
            serverName: "S",
            serverContext: "",
            tools: [],
            permissionLevel: .strict,
            skillSummaries: ""
        )
        #expect(prompt.contains("require user confirmation"))
    }

    @Test("permissive 模式包含自动执行提示")
    func permissivePermission() {
        let prompt = SystemPromptBuilder.build(
            serverName: "S",
            serverContext: "",
            tools: [],
            permissionLevel: .permissive,
            skillSummaries: ""
        )
        #expect(prompt.contains("auto-execute"))
    }

    @Test("包含 Working Principles")
    func workingPrinciplesPresent() {
        let prompt = SystemPromptBuilder.build(
            serverName: "S",
            serverContext: "",
            tools: [],
            permissionLevel: .standard,
            skillSummaries: ""
        )
        #expect(prompt.contains("Action First"))
        #expect(prompt.contains("Trust the Context"))
        #expect(prompt.contains("Step by Step"))
        #expect(prompt.contains("Fail Gracefully"))
        #expect(prompt.contains("Use Memory"))
    }

    @Test("包含 Context Efficiency")
    func contextEfficiencyPresent() {
        let prompt = SystemPromptBuilder.build(
            serverName: "S",
            serverContext: "",
            tools: [],
            permissionLevel: .standard,
            skillSummaries: ""
        )
        #expect(prompt.contains("Context Efficiency"))
        #expect(prompt.contains("Combine related commands"))
    }

    @Test("有 skill summaries 时注入 Available Skills 和 fallback 指导")
    func skillSummariesInjected() {
        let prompt = SystemPromptBuilder.build(
            serverName: "S",
            serverContext: "",
            tools: [],
            permissionLevel: .standard,
            skillSummaries: "- health-check: Check server health"
        )
        #expect(prompt.contains("Available Skills"))
        #expect(prompt.contains("health-check"))
        #expect(prompt.contains("plan the stages yourself"))
    }

    @Test("无 skill summaries 时不注入 Available Skills")
    func noSkillSummariesWhenEmpty() {
        let prompt = SystemPromptBuilder.build(
            serverName: "S",
            serverContext: "",
            tools: [],
            permissionLevel: .standard,
            skillSummaries: ""
        )
        #expect(!prompt.contains("Available Skills"))
    }

    @Test("包含计算资源引导")
    func computingResourceGuidance() {
        let prompt = SystemPromptBuilder.build(
            serverName: "S",
            serverContext: "",
            tools: [],
            permissionLevel: .standard,
            skillSummaries: ""
        )
        #expect(prompt.contains("server as your execution environment"))
    }

    @Test("不再包含旧的编号规则和 personality 引导")
    func oldRulesRemoved() {
        let prompt = SystemPromptBuilder.build(
            serverName: "S",
            serverContext: "",
            tools: [],
            permissionLevel: .standard,
            skillSummaries: ""
        )
        #expect(!prompt.contains("update_personality_style"))
        #expect(!prompt.contains("Wake up, my friend"))
        #expect(!prompt.contains("Active Skill:"))
        #expect(!prompt.contains("Available tool names:"))
    }

    @Test("prompt 段落顺序正确")
    func sectionOrdering() {
        let prompt = SystemPromptBuilder.build(
            serverName: "S",
            serverContext: "ctx",
            tools: [],
            permissionLevel: .standard,
            skillSummaries: "- s1: d1"
        )
        let toneIdx = prompt.range(of: "Tone & Style")!.lowerBound
        let mandatesIdx = prompt.range(of: "Core Mandates")!.lowerBound
        let contextIdx = prompt.range(of: "Server Context")!.lowerBound
        let principlesIdx = prompt.range(of: "Working Principles")!.lowerBound
        let efficiencyIdx = prompt.range(of: "Context Efficiency")!.lowerBound
        let skillsIdx = prompt.range(of: "Available Skills")!.lowerBound

        #expect(toneIdx < mandatesIdx)
        #expect(mandatesIdx < contextIdx)
        #expect(contextIdx < principlesIdx)
        #expect(principlesIdx < efficiencyIdx)
        #expect(efficiencyIdx < skillsIdx)
    }
}
