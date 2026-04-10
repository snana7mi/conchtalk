/// 文件说明：GlowBorderModifier，为列表行和头像添加流光边框效果。
import SwiftUI

/// GlowBorderModifier：为列表行添加旋转渐变流光边框。
struct GlowBorderModifier: ViewModifier {
    let isActive: Bool

    // In iOS lists, standard state-based repeating animations can sometimes freeze.
    // A TimelineView ensures continuous redraws for fluid rotation.
    func body(content: Content) -> some View {
        if isActive {
            content
                .listRowBackground(
                    ZStack {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.secondary.opacity(0.08))

                        TimelineView(.animation) { timeline in
                            let now = timeline.date.timeIntervalSinceReferenceDate
                            let fraction = now.truncatingRemainder(dividingBy: 2.0) / 2.0
                            let angle = Angle.degrees(fraction * 360)

                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(
                                    AngularGradient(
                                        gradient: Gradient(colors: [
                                            .green,
                                            .mint,
                                            .cyan,
                                            .blue,
                                            .purple,
                                            .pink,
                                            .yellow,
                                            .green
                                        ]),
                                        center: .center,
                                        angle: angle
                                    ),
                                    lineWidth: 2.5
                                )
                        }
                    }
                    .padding(6)
                )
        } else {
            content
        }
    }
}

/// DLCGlowBorderModifier：DLC 代理运行中的彩虹流光边框。
struct DLCGlowBorderModifier: ViewModifier {
    let isActive: Bool

    func body(content: Content) -> some View {
        if isActive {
            content
                .listRowBackground(
                    ZStack {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.secondary.opacity(0.08))
                        TimelineView(.animation) { timeline in
                            let now = timeline.date.timeIntervalSinceReferenceDate
                            let fraction = now.truncatingRemainder(dividingBy: 3.0) / 3.0
                            let angle = Angle.degrees(fraction * 360)
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(
                                    AngularGradient(
                                        gradient: Gradient(colors: [
                                            .red, .orange, .yellow, .green,
                                            .cyan, .blue, .purple, .pink, .red
                                        ]),
                                        center: .center,
                                        angle: angle
                                    ),
                                    lineWidth: 2.5
                                )
                        }
                    }
                    .padding(6)
                )
        } else {
            content
        }
    }
}

/// RainbowAvatarBorder：为 Pro 用户头像添加流动彩虹荧光边框。
struct RainbowAvatarBorder: ViewModifier {
    let isActive: Bool
    let size: CGFloat
    /// 边框宽度
    let lineWidth: CGFloat
    /// 外发光模糊半径
    let glowRadius: CGFloat

    init(isActive: Bool, size: CGFloat, lineWidth: CGFloat = 3, glowRadius: CGFloat = 6) {
        self.isActive = isActive
        self.size = size
        self.lineWidth = lineWidth
        self.glowRadius = glowRadius
    }

    func body(content: Content) -> some View {
        if isActive {
            content
                .overlay {
                    TimelineView(.animation) { timeline in
                        let now = timeline.date.timeIntervalSinceReferenceDate
                        let fraction = now.truncatingRemainder(dividingBy: 3.0) / 3.0
                        let angle = Angle.degrees(fraction * 360)

                        let gradient = AngularGradient(
                            gradient: Gradient(colors: [
                                .red, .orange, .yellow, .green,
                                .cyan, .blue, .purple, .pink, .red
                            ]),
                            center: .center,
                            angle: angle
                        )

                        Circle()
                            .strokeBorder(gradient, lineWidth: lineWidth)
                            .frame(width: size + lineWidth * 2, height: size + lineWidth * 2)
                            // 外发光层
                            .blur(radius: glowRadius)
                            .opacity(0.6)

                        Circle()
                            .strokeBorder(gradient, lineWidth: lineWidth)
                            .frame(width: size + lineWidth * 2, height: size + lineWidth * 2)
                    }
                }
                .padding(lineWidth + glowRadius * 0.5)
        } else {
            content
        }
    }
}

extension View {
    /// 为 Pro 用户头像添加流动彩虹荧光边框。
    func rainbowAvatarBorder(isActive: Bool, size: CGFloat, lineWidth: CGFloat = 3, glowRadius: CGFloat = 6) -> some View {
        modifier(RainbowAvatarBorder(isActive: isActive, size: size, lineWidth: lineWidth, glowRadius: glowRadius))
    }
}
