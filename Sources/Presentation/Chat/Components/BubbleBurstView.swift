/// 文件说明：BubbleBurstView，iOS 上拉水晶泡沫膜与底缘迸裂动效，用于触发上下文分割。
import SwiftUI

// MARK: - 上拉膜（交互 + 视觉共用常量）

/// BubblePullInteraction：底部上拉膜的行程与最大高度（状态机与 `MembraneBubbleView` 共用）。
enum BubblePullInteraction {
    /// 进入 armed 的 overscroll（pt）；可撤回，故略低以便轻松进入
    static let armedOverscrollPoints: CGFloat = 50
    /// 拉动进度归一化用：此 overscroll 时进度为 1（与 armed 解耦，可保持较大以「多拉才顶满」）
    static let visualFullOverscrollPoints: CGFloat = 145
    /// 进度为 1 时膜面顶点高度（pt）
    static let membraneMaxHeightPoints: CGFloat = 138
    /// 膜迸裂动效时长（与 schedule 完成回调一致）
    static let membraneBurstDuration: TimeInterval = 0.48
}

// MARK: - 状态枚举

/// BubbleGestureState：气泡手势状态机。
/// idle → pulling → ready → burst → idle
enum BubbleGestureState: Equatable {
    /// 无手势
    case idle
    /// 上拉中，offset 为 overscroll（0…armedOverscroll）
    case pulling(offset: CGFloat)
    /// 已就绪，松手即破裂。offset ≥ armedOverscroll
    case ready(offset: CGFloat)
    /// 破裂动画播放中
    case burst

    /// 当前 overscroll 偏移量（idle/burst 返回 0）
    var offset: CGFloat {
        switch self {
        case .idle, .burst: return 0
        case .pulling(let offset), .ready(let offset): return offset
        }
    }

    /// 是否处于就绪状态
    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}

// MARK: - Membrane Shape

/// MembraneCapShape：膜面上沿的半椭圆形状（底部固定在边缘）。
struct MembraneCapShape: Shape {
    /// 张力（0~1），越大越接近半圆
    var tension: CGFloat

    var animatableData: CGFloat {
        get { tension }
        set { tension = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let width = rect.width
        let height = rect.height
        guard width > 0, height > 0 else { return Path() }

        let clamped = max(0, min(1, tension))
        // 略提高指数使肩线更圆，少「折角」感
        let exponent = 0.42 + 0.09 * clamped
        let radiusX = width / 2
        let radiusY = height
        let centerX = rect.midX
        let baseY = rect.maxY
        let steps = 64

        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: baseY))
        for step in 0...steps {
            let t = CGFloat(step) / CGFloat(steps)
            // smoothstep：端点导数为 0，与底边衔接更顺
            let s = t * t * (3 - 2 * t)
            let x = rect.minX + width * s
            let normalized = (x - centerX) / radiusX
            let base = max(0, 1 - normalized * normalized)
            let curve = pow(base, exponent)
            let y = baseY - radiusY * curve
            path.addLine(to: CGPoint(x: x, y: y))
        }
        path.addLine(to: CGPoint(x: rect.maxX, y: baseY))
        path.closeSubpath()
        return path
    }
}

/// MembraneRimShape：膜面顶部高光边缘。
struct MembraneRimShape: Shape {
    var tension: CGFloat

    var animatableData: CGFloat {
        get { tension }
        set { tension = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let width = rect.width
        let height = rect.height
        guard width > 0, height > 0 else { return Path() }

        let clamped = max(0, min(1, tension))
        let exponent = 0.42 + 0.09 * clamped
        let radiusX = width / 2
        let radiusY = height
        let centerX = rect.midX
        let baseY = rect.maxY
        let steps = 64

        var path = Path()
        for step in 0...steps {
            let t = CGFloat(step) / CGFloat(steps)
            let s = t * t * (3 - 2 * t)
            let x = rect.minX + width * s
            let normalized = (x - centerX) / radiusX
            let base = max(0, 1 - normalized * normalized)
            let curve = pow(base, exponent)
            let y = baseY - radiusY * curve
            if step == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        return path
    }
}

// MARK: - 水晶泡沫膜

/// MembraneBubbleView：底部全宽水晶泡沫膜（磨砂 + 薄膜色散 + 高光），高度仅由 progress 连续驱动（armed 不跳变）。
struct MembraneBubbleView: View {
    /// 归一化的拉动进度（0~1），由实时 overscroll / visualFull 得到，跨 pulling / armed 连续
    let progress: CGFloat
    /// 已 armed：仅影响干涉色转速等，不改变几何高度
    let isReady: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Metrics {
        let height: CGFloat
        let tension: CGFloat
        let glow: CGFloat
        let rimWidth: CGFloat
        let lipHeight: CGFloat
        let highlightOpacity: CGFloat
    }

    private func metrics(for progress: CGFloat) -> Metrics {
        let clamped = max(0, min(1, progress))
        let heightGrowth = pow(clamped, 0.62)

        let maxHeight = BubblePullInteraction.membraneMaxHeightPoints
        let minHeight: CGFloat = 12

        let height = minHeight + (maxHeight - minHeight) * heightGrowth

        let tension = max(0, min(1, height / maxHeight))
        let glow = 6 + clamped * 10
        let rimWidth = 0.5 + clamped * 0.75
        let lipHeight = max(1, height * 0.1)
        let highlightOpacity = 0.22 + clamped * 0.28

        return Metrics(
            height: height,
            tension: tension,
            glow: glow,
            rimWidth: rimWidth,
            lipHeight: lipHeight,
            highlightOpacity: highlightOpacity
        )
    }

    private var timelineInterval: TimeInterval {
        isReady ? (1.0 / 60.0) : (1.0 / 24.0)
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: timelineInterval, paused: reduceMotion)) { timeline in
            let elapsed = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
            let current = metrics(for: progress)
            let p = max(0, min(progress, 1.0))
            // ready 时略加快干涉色转动，形成「活」感；不用位移动画，避免底边跟着晃
            let rotationSpeed: Double = reduceMotion ? 0 : (isReady ? 95 : 32)
            let angle = Angle.degrees(elapsed * rotationSpeed)
            let shape = MembraneCapShape(tension: current.tension)
            let rim = MembraneRimShape(tension: current.tension)

            GeometryReader { geo in
                let w = max(geo.size.width, 1)
                let filmStrength = 0.22 + p * 0.2

                ZStack {
                    // 磨砂玻璃底（透明感主来源）
                    shape
                        .fill(.ultraThinMaterial)
                        .opacity(0.78 + p * 0.12)

                    // 薄膜干涉：极淡，靠透明叠色
                    shape
                        .fill(
                            AngularGradient(
                                colors: [
                                    Color(red: 0.72, green: 0.88, blue: 1.0),
                                    Color(red: 0.88, green: 0.78, blue: 1.0),
                                    Color(red: 0.70, green: 0.94, blue: 0.92),
                                    Color(red: 0.82, green: 0.84, blue: 1.0),
                                    Color(red: 0.75, green: 0.90, blue: 0.98),
                                    Color(red: 0.72, green: 0.88, blue: 1.0),
                                ],
                                center: UnitPoint(x: 0.5, y: 0.88),
                                startAngle: angle,
                                endAngle: angle + .degrees(360)
                            )
                        )
                        .opacity(filmStrength * 0.38)
                        .blendMode(.plusLighter)

                    // 泡顶聚光（淡）
                    shape
                        .fill(
                            RadialGradient(
                                colors: [
                                    Color.white.opacity(0.38),
                                    Color.white.opacity(0.04),
                                    Color(red: 0.65, green: 0.92, blue: 1.0).opacity(0.12),
                                    Color.clear,
                                ],
                                center: UnitPoint(x: 0.5, y: 0.06),
                                startRadius: 0,
                                endRadius: max(w, current.height) * 0.95
                            )
                        )
                        .blendMode(.screen)

                    // 自上而下霜面高光
                    shape
                        .fill(
                            LinearGradient(
                                stops: [
                                    .init(color: Color.white.opacity(0.28), location: 0),
                                    .init(color: Color.white.opacity(0.04), location: 0.4),
                                    .init(color: Color.clear, location: 1),
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .blendMode(.screen)

                    Rectangle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.22),
                                    Color.white.opacity(0.0),
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(height: current.lipHeight * 1.25)
                        .offset(y: current.height - current.lipHeight * 1.25)
                        .mask(shape)

                    rim
                        .stroke(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.55),
                                    Color(red: 0.82, green: 0.94, blue: 1.0).opacity(0.45),
                                    Color.white.opacity(0.28),
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            ),
                            lineWidth: current.rimWidth
                        )
                        .opacity(current.highlightOpacity)

                    // 主高光（左侧）
                    Ellipse()
                        .fill(
                            RadialGradient(
                                colors: [
                                    Color.white.opacity(0.42),
                                    Color.white.opacity(0.0),
                                ],
                                center: .center,
                                startRadius: 0,
                                endRadius: max(12, w * 0.08)
                            )
                        )
                        .frame(width: w * 0.22, height: current.height * 0.26)
                        .blur(radius: 4)
                        .offset(x: -w * 0.26, y: -current.height * 0.4)
                        .blendMode(.screen)

                    // 次高光（右侧）
                    Ellipse()
                        .fill(
                            RadialGradient(
                                colors: [
                                    Color.white.opacity(0.22),
                                    Color.clear,
                                ],
                                center: .center,
                                startRadius: 0,
                                endRadius: w * 0.05
                            )
                        )
                        .frame(width: w * 0.1, height: current.height * 0.12)
                        .offset(x: w * 0.24, y: -current.height * 0.36)
                        .blendMode(.softLight)
                }
                .frame(width: w, height: current.height, alignment: .bottom)
            }
            .frame(height: current.height)
            .compositingGroup()
            .shadow(color: Color.white.opacity(0.06 + p * 0.08), radius: current.glow * 0.35, x: 0, y: -1)
            .shadow(color: Color(red: 0.55, green: 0.88, blue: 1.0).opacity(0.08 + p * 0.08), radius: current.glow * 0.85, x: 0, y: 0)
        }
    }
}

// MARK: - 膜迸裂动效

/// MembraneShardShape：沿底边全宽弧面切开的一瓣膜（与拉起时同族抛物线轮廓 + 上沿撕口）。
private struct MembraneShardShape: Shape {
    let index: Int
    let count: Int
    /// 0~1，上沿中点额外下凹，模拟撕裂
    let tearDepth: CGFloat

    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        guard w > 0, h > 0, count > 0 else { return Path() }

        let n = CGFloat(count)
        let x0 = CGFloat(index) / n * w
        let x1 = CGFloat(index + 1) / n * w
        let cx = w / 2
        func curveLift(_ x: CGFloat) -> CGFloat {
            let nx = (x - cx) / max(w / 2, 0.5)
            let base = max(0, 1 - nx * nx)
            return pow(base, 0.52) * h * 0.96
        }
        let y0 = h - curveLift(x0)
        let y1 = h - curveLift(x1)
        let midX = (x0 + x1) / 2
        let yMid = h - curveLift(midX) - tearDepth * min(14, h * 0.09)

        var path = Path()
        path.move(to: CGPoint(x: x0, y: h))
        path.addLine(to: CGPoint(x: x1, y: h))
        path.addLine(to: CGPoint(x: x1, y: y1))
        path.addLine(to: CGPoint(x: midX, y: yMid))
        path.addLine(to: CGPoint(x: x0, y: y0))
        path.closeSubpath()
        return path
    }
}

/// MembraneBurstView：底缘整片膜沿弧顶迸裂，楔形瓣向外飞散并淡出（非独立碎块）。
struct MembraneBurstView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let wedgeCount = 14

    private struct WedgeConfig: Identifiable {
        let id: Int
        let tearDepth: CGFloat
        let distance: CGFloat
        let drift: CGFloat
        let spin: Double
    }

    @State private var configs: [WedgeConfig] = []
    @State private var phase: CGFloat = 0

    private let burstDuration = BubblePullInteraction.membraneBurstDuration

    var body: some View {
        GeometryReader { geo in
            let w = max(geo.size.width, 1)
            let h = max(geo.size.height, 1)
            ZStack {
                // 底缘一圈放射闪光（膜被戳穿的瞬间）
                RadialGradient(
                    colors: [
                        Color.white.opacity(0.55),
                        Color(red: 0.75, green: 0.92, blue: 1.0).opacity(0.35),
                        Color.clear,
                    ],
                    center: UnitPoint(x: 0.5, y: 1.0),
                    startRadius: 2,
                    endRadius: w * 0.55
                )
                .scaleEffect(phase > 0 ? 1.35 : 0.2, anchor: UnitPoint(x: 0.5, y: 1.0))
                .opacity(reduceMotion ? 0 : Double(1 - phase) * 0.9)
                .allowsHitTesting(false)

                ForEach(configs) { cfg in
                    shardView(cfg: cfg, width: w, height: h)
                }
            }
            .frame(width: w, height: h, alignment: .bottom)
        }
        .frame(height: BubblePullInteraction.membraneMaxHeightPoints + 24)
        .onAppear {
            if configs.isEmpty {
                configs = Self.makeConfigs(count: Self.wedgeCount)
            }
            if reduceMotion {
                phase = 1
                return
            }
            withAnimation(.easeOut(duration: burstDuration)) {
                phase = 1
            }
        }
    }

    private func shardView(cfg: WedgeConfig, width w: CGFloat, height h: CGFloat) -> some View {
        let cx = w / 2
        let n = CGFloat(Self.wedgeCount)
        let x0 = CGFloat(cfg.id) / n * w
        let x1 = CGFloat(cfg.id + 1) / n * w
        let midX = (x0 + x1) / 2
        let liftMid = Self.membraneCurveLift(x: midX, width: w, height: h)
        let yMid = h - liftMid - cfg.tearDepth * min(14, h * 0.09)
        let dx = midX - cx
        let dy = yMid - h
        let len = max(0.001, hypot(dx, dy))
        let nx = dx / len
        let ny = dy / len
        let px = -ny
        let py = nx
        let travel = phase * cfg.distance
        let lateral = phase * cfg.drift

        return MembraneShardShape(index: cfg.id, count: Self.wedgeCount, tearDepth: cfg.tearDepth)
            .fill(
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.42),
                        Color(red: 0.72, green: 0.88, blue: 1.0).opacity(0.38),
                        Color(red: 0.85, green: 0.78, blue: 1.0).opacity(0.28),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .overlay(
                MembraneShardShape(index: cfg.id, count: Self.wedgeCount, tearDepth: cfg.tearDepth)
                    .stroke(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.65),
                                Color.white.opacity(0.18),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.9
                    )
            )
            .rotationEffect(.degrees(phase * cfg.spin))
            .offset(
                x: nx * travel + px * lateral,
                y: ny * travel + py * lateral * 0.35
            )
            .opacity(1 - phase)
            .scaleEffect(1 - phase * 0.12)
    }

    /// 与 `MembraneShardShape.path` 里弧顶一致，用于计算迸裂飞出方向
    private static func membraneCurveLift(x: CGFloat, width w: CGFloat, height h: CGFloat) -> CGFloat {
        let cx = w / 2
        let nx = (x - cx) / max(w / 2, 0.5)
        let base = max(0, 1 - nx * nx)
        return pow(base, 0.52) * h * 0.96
    }

    private static func makeConfigs(count: Int) -> [WedgeConfig] {
        var rng = SystemRandomNumberGenerator()
        return (0..<count).map { i in
            WedgeConfig(
                id: i,
                tearDepth: CGFloat.random(in: 0.25...1.0, using: &rng),
                distance: CGFloat.random(in: 42...88, using: &rng),
                drift: CGFloat.random(in: -14...14, using: &rng),
                spin: Double.random(in: -18...18, using: &rng)
            )
        }
    }
}

// MARK: - 主视图

/// BubbleBurstView：
/// 根据 BubbleGestureState 渲染对应阶段的视觉效果。
/// - pulling/ready：水晶泡沫膜从底部被拉起，越拉越大
/// - burst：底缘整膜迸裂
/// - idle：不渲染
struct BubbleBurstView: View {
    let state: BubbleGestureState

    /// 拉动进度（0~1），与 overscroll 线性归一；armed 与 pulling 共用连续曲线，无阈值处跳变
    private var progress: CGFloat {
        min(1, state.offset / BubblePullInteraction.visualFullOverscrollPoints)
    }

    var body: some View {
        ZStack {
            switch state {
            case .idle:
                EmptyView()

            case .pulling, .ready:
                MembraneBubbleView(
                    progress: progress,
                    isReady: state.isReady
                )

            case .burst:
                MembraneBurstView()
            }
        }
        .frame(maxWidth: .infinity)
        .ignoresSafeArea(edges: .horizontal)
        .allowsHitTesting(false)
    }
}
