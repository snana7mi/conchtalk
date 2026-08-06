/// 文件说明：ConchRippleView，海螺声波扩散环动画，语音识别时显示。
import SwiftUI

private extension Color {
    static let rippleTeal1 = Color(red: 0, green: 200.0/255, blue: 180.0/255)  // #00C8B4
    static let rippleTeal2 = Color(red: 0, green: 180.0/255, blue: 200.0/255)  // #00B4C8
    static let rippleTeal3 = Color(red: 0, green: 160.0/255, blue: 220.0/255)  // #00A0DC
}

/// ConchRippleView：海螺按钮 + 蓝绿色扩散环动画。
/// 用于语音识别期间，替代简单的缩放脉冲，提供更丰富的视觉反馈。
struct ConchRippleView: View {
    let isListening: Bool
    let isFinishing: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if isListening || isFinishing {
                if reduceMotion {
                    // 无障碍：静态指示环
                    Circle()
                        .stroke(Color.rippleTeal1, lineWidth: 1)
                        .frame(width: 28, height: 28)
                        .opacity(0.6)
                } else if isListening {
                    rippleRings(cycleDuration: 2.4, startOpacity: 0.7)
                } else if isFinishing {
                    rippleRings(cycleDuration: 3.6, startOpacity: 0.4)
                }
            }

            Text("\u{1F41A}")
                .font(.system(size: 18))
                .scaleEffect(conchScale)
                .opacity(isListening || isFinishing ? 1.0 : 0.5)
                .animation(conchAnimation, value: isListening)
                .animation(conchAnimation, value: isFinishing)
        }
        .frame(width: 28, height: 28)
        .animation(.easeOut(duration: 0.5), value: isListening)
        .animation(.easeOut(duration: 0.5), value: isFinishing)
    }

    @ViewBuilder
    private func rippleRings(cycleDuration: Double, startOpacity: Double) -> some View {
        Group {
            RippleRing(delay: 0, color: .rippleTeal1, cycleDuration: cycleDuration, startOpacity: startOpacity)
            RippleRing(delay: cycleDuration / 3, color: .rippleTeal2, cycleDuration: cycleDuration, startOpacity: startOpacity)
            RippleRing(delay: cycleDuration / 3 * 2, color: .rippleTeal3, cycleDuration: cycleDuration, startOpacity: startOpacity)
        }
        .allowsHitTesting(false)
        .transition(.opacity)
    }

    private var conchScale: CGFloat {
        if isListening { return 1.15 }
        if isFinishing { return 1.05 }
        return 1.0
    }

    private var conchAnimation: Animation? {
        if isListening || isFinishing {
            return .easeInOut(duration: 1.2).repeatForever(autoreverses: true)
        }
        return nil
    }
}

/// 单个扩散环，使用隐式动画驱动扩散效果。
private struct RippleRing: View {
    let delay: Double
    let color: Color
    let cycleDuration: Double
    let startOpacity: Double

    @State private var animating = false

    var body: some View {
        Circle()
            .stroke(color, lineWidth: 2)
            .frame(width: 28, height: 28)
            .scaleEffect(animating ? 2.2 : 1.0)
            .opacity(animating ? 0 : startOpacity)
            .animation(
                .easeOut(duration: cycleDuration)
                    .repeatForever(autoreverses: false)
                    .delay(delay),
                value: animating
            )
            .onAppear {
                animating = true
            }
    }
}
