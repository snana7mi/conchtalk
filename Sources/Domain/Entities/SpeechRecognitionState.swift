/// 文件说明：SpeechRecognitionState，语音识别状态枚举。
import Foundation

/// SpeechRecognitionState：
/// 表示语音识别服务的当前工作状态。
enum SpeechRecognitionState: Sendable, Equatable {
    /// 空闲，未在录音
    case idle
    /// 录音中，partialText 为实时识别的部分文本
    case listening(partialText: String)
    /// 检测到静默，正在完成最终识别
    case finishing
    /// 发生错误
    case error(String)
}

/// SilenceDetectionConfig：
/// 静默检测参数，内部常量不暴露给用户设置界面。
struct SilenceDetectionConfig: Sendable {
    /// RMS 音频电平阈值，低于此值视为静默
    var silenceThreshold: Float
    /// 连续静默多久后自动停止（秒）
    var silenceDuration: TimeInterval
    /// 开始录音后的宽限期，忽略初始静默（秒）
    var gracePeriod: TimeInterval
    /// 最大录音时长（秒），兜底防护
    var maxDuration: TimeInterval

    nonisolated init(
        silenceThreshold: Float = 0.02,
        silenceDuration: TimeInterval = 2.5,
        gracePeriod: TimeInterval = 1.0,
        maxDuration: TimeInterval = 60
    ) {
        self.silenceThreshold = silenceThreshold
        self.silenceDuration = silenceDuration
        self.gracePeriod = gracePeriod
        self.maxDuration = maxDuration
    }
}
