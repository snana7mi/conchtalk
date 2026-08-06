/// 文件说明：SpeechInputCoordinator，封装语音识别的状态管理与文本合并逻辑。

import Foundation

/// SpeechInputCoordinator：
/// 管理语音识别会话的生命周期，将识别结果合并到输入文本中。
/// 从 ChatViewModel 中抽离，使 ViewModel 只需持有引用和转发属性。
@MainActor @Observable
final class SpeechInputCoordinator {

    var speechRecognitionService: SpeechRecognitionProtocol

    /// 当前语音识别会话开始前的输入框内容，用于将识别结果追加到已有文字后。
    private var speechInputBaseText: String?

    init(speechRecognitionService: SpeechRecognitionProtocol) {
        self.speechRecognitionService = speechRecognitionService
    }

    /// 语音识别是否可用（用于决定是否显示麦克风按钮）。
    var isAvailable: Bool {
        speechRecognitionService.isAvailable
    }

    /// 当前是否正在录音。
    var isListening: Bool {
        if case .listening = speechRecognitionService.state { return true }
        return false
    }

    /// 语音识别状态。
    var state: SpeechRecognitionState {
        speechRecognitionService.state
    }

    /// 切换语音识别状态：idle → 开始录音，listening → 停止录音。
    /// - Parameter currentText: 当前输入框文本。
    /// - Returns: 合并后的新文本（如果有变更），调用方据此更新 inputText。
    func toggle(currentText: String) async -> String? {
        switch speechRecognitionService.state {
        case .listening:
            let text = await speechRecognitionService.stopListening()
            let result: String? = text.isEmpty ? nil : mergedSpeechText(text)
            speechInputBaseText = nil
            return result
        case .idle, .error:
            do {
                speechInputBaseText = currentText
                try await speechRecognitionService.startListening(locale: .current)
            } catch {
                speechInputBaseText = nil
            }
            return nil
        default:
            return nil
        }
    }

    /// 同步语音识别的 partial text 到 inputText（由 UI observation 驱动）。
    func syncPartialText(to inputText: inout String) {
        if case .listening(let partialText) = speechRecognitionService.state, !partialText.isEmpty {
            inputText = mergedSpeechText(partialText)
        }
    }

    private func mergedSpeechText(_ recognizedText: String) -> String {
        guard let speechInputBaseText else { return recognizedText }
        return speechInputBaseText + recognizedText
    }
}
