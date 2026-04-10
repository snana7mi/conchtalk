/// 文件说明：MockSpeechRecognitionService，语音识别服务的测试替身。
@testable import ConchTalk
import Foundation

@MainActor
@Observable
final class MockSpeechRecognitionService: SpeechRecognitionProtocol, @unchecked Sendable {
    private(set) var state: SpeechRecognitionState = .idle
    var isAvailable: Bool = true

    /// 记录调用
    var startListeningCallCount = 0
    var stopListeningCallCount = 0
    var cancelListeningCallCount = 0
    var lastLocale: Locale?

    /// 控制行为
    var startListeningError: Error?
    var stopListeningResult: String = ""

    func startListening(locale: Locale) async throws {
        startListeningCallCount += 1
        lastLocale = locale
        if let error = startListeningError {
            throw error
        }
        state = .listening(partialText: "")
    }

    func stopListening() async -> String {
        stopListeningCallCount += 1
        state = .idle
        return stopListeningResult
    }

    func cancelListening() async {
        cancelListeningCallCount += 1
        state = .idle
    }

    /// 测试辅助：模拟 partial result 更新
    func simulatePartialResult(_ text: String) {
        state = .listening(partialText: text)
    }

    /// 测试辅助：模拟错误
    func simulateError(_ message: String) {
        state = .error(message)
    }
}
