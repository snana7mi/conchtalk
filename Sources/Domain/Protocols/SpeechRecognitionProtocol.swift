/// 文件说明：SpeechRecognitionProtocol，语音识别服务抽象契约。
import Foundation

/// SpeechRecognitionProtocol：
/// 定义语音识别服务的公共接口，支持 mock 替换。
@MainActor
protocol SpeechRecognitionProtocol: AnyObject, Sendable {
    /// 当前识别状态
    var state: SpeechRecognitionState { get }
    /// 设备是否支持语音识别且权限已授权
    var isAvailable: Bool { get }

    /// 开始语音识别
    /// - Parameter locale: 识别语言，默认跟随设备 Locale
    func startListening(locale: Locale) async throws
    /// 手动停止语音识别，返回最终识别文本
    func stopListening() async -> String
    /// 取消语音识别，丢弃所有结果
    func cancelListening() async
}
