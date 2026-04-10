/// 文件说明：HapticFeedback，封装 iOS 触觉反馈调用。
import Foundation

import UIKit

/// HapticFeedback：封装 iOS 触觉反馈方法。
enum HapticFeedback {
    /// 连接成功时的触觉反馈（中等强度冲击）
    static func connectionSuccess() {
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.impactOccurred()
    }

    /// 气泡就绪时的触觉反馈（中等强度，带 prepare 确保手势期间及时触发）
    static func bubbleReady() {
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.prepare()
        generator.impactOccurred()
    }

    /// 上下文清理时的触觉反馈（较强冲击感）
    static func contextBreak() {
        let generator = UIImpactFeedbackGenerator(style: .heavy)
        generator.prepare()
        generator.impactOccurred()
    }
}
