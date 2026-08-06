/// 文件说明：AgentLogoProvider，根据 AgentType 提供品牌 Logo 图片。
import SwiftUI

/// AgentLogoProvider：
/// 封装编码代理品牌 Logo 的获取逻辑，供直连模式下气泡头像使用。
enum AgentLogoProvider {
    /// 返回指定 agent 的品牌 Logo View（40×40，圆角裁剪）。
    static func logo(for agentType: AgentType) -> some View {
        Image(agentType.logoAssetName)
            .resizable()
            .scaledToFit()
            .frame(width: 40, height: 40)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .accessibilityLabel(agentType.displayName)
    }
}
