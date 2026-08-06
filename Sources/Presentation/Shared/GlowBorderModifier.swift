/// 文件说明：GlowBorderModifier，为已连接服务器列表行添加流光边框效果。
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
