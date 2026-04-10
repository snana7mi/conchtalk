/// 文件说明：ServerCapabilitiesTests，测试 ServerCapabilities 实体的默认值与属性行为。
import Testing
@testable import ConchTalk

@Suite("ServerCapabilities Entity")
struct ServerCapabilitiesTests {

    // MARK: - unknown 默认值

    @Test("unknown：静态默认值 availableAgents 为空")
    func unknownDefault() {
        let caps = ServerCapabilities.unknown
        #expect(caps.availableAgents.isEmpty)
    }

    // MARK: - logoAssetName

    @Test("每个 AgentType 都有非空的 logoAssetName")
    func allAgentTypesHaveLogoAssetName() {
        for agentType in AgentType.allCases {
            #expect(!agentType.logoAssetName.isEmpty, "Missing logoAssetName for \(agentType)")
        }
    }

    @Test("logoAssetName 遵循 logo- 前缀命名约定")
    func logoAssetNameFollowsNamingConvention() {
        for agentType in AgentType.allCases {
            #expect(agentType.logoAssetName.hasPrefix("logo-"), "\(agentType).logoAssetName should start with 'logo-'")
        }
    }

    // MARK: - from(displayName:)

    @Test("from(displayName:) 能正确反查每个 AgentType")
    func fromDisplayNameMatchesAll() {
        for agentType in AgentType.allCases {
            let result = AgentType.from(displayName: agentType.displayName)
            #expect(result == agentType, "from(displayName:) failed for \(agentType.displayName)")
        }
    }

    @Test("from(displayName:) 对未知名称返回 nil")
    func fromDisplayNameUnknownReturnsNil() {
        #expect(AgentType.from(displayName: "NotAnAgent") == nil)
        #expect(AgentType.from(displayName: "") == nil)
    }

    @Test("from(displayName:) 支持 rawValue 与大小写差异")
    func fromDisplayNameAcceptsRawValueAndCaseVariants() {
        #expect(AgentType.from(displayName: "opencode") == .opencode)
        #expect(AgentType.from(displayName: "OPENCLAW") == .openclaw)
        #expect(AgentType.from(displayName: "Claude Code 1.2.3") == .claude)
    }
}
