/// 文件说明：AgentLogoProviderTests，测试品牌 Logo 提供逻辑。
import Testing
import SwiftUI
@testable import ConchTalk

@Suite("AgentLogoProvider")
struct AgentLogoProviderTests {

    @Test("logo(for:) 对每个 AgentType 不 crash")
    func logoForAllAgentTypes() {
        for agentType in AgentType.allCases {
            let _ = AgentLogoProvider.logo(for: agentType)
        }
    }

    #if canImport(AppKit)
    @Test("每个 AgentType 的 logo asset 在 bundle 中存在")
    func logoAssetsExistInBundle() {
        for agentType in AgentType.allCases {
            let image = NSImage(named: agentType.logoAssetName)
            #expect(image != nil, "Missing logo asset for \(agentType): \(agentType.logoAssetName)")
        }
    }
    #elseif canImport(UIKit)
    @Test("每个 AgentType 的 logo asset 在 bundle 中存在")
    func logoAssetsExistInBundle() {
        for agentType in AgentType.allCases {
            let image = UIImage(named: agentType.logoAssetName)
            #expect(image != nil, "Missing logo asset for \(agentType): \(agentType.logoAssetName)")
        }
    }
    #endif
}
