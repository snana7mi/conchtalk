/// 文件说明：SpeechRecognitionServiceTests，验证语音识别服务的状态管理与静默检测逻辑。
import Testing
@testable import ConchTalk
import Foundation

@MainActor
struct SpeechRecognitionServiceTests {
    @Test func initialStateIsIdle() {
        let permissionManager = AudioPermissionManager()
        let service = SpeechRecognitionService(permissionManager: permissionManager)
        #expect(service.state == .idle)
    }

    @Test func silenceDetectionConfigDefaults() {
        let config = SilenceDetectionConfig()
        #expect(config.silenceThreshold == 0.02)
        #expect(config.silenceDuration == 2.5)
        #expect(config.gracePeriod == 1.0)
        #expect(config.maxDuration == 60)
    }

    // 移除了 isAvailableReflectsRecognizerAvailability：它断言两个独立 SFSpeechRecognizer()
    // 实例的 .isAvailable 相等，而该属性异步 settle、逐实例竞态 → 重言式且天生 flaky，测不出真实逻辑。
    // 如需确定性测可用性，应把 recognizer 改为可注入再 stub。

    @Test func cancelListeningResetsToIdle() async {
        let permissionManager = AudioPermissionManager()
        let service = SpeechRecognitionService(permissionManager: permissionManager)
        await service.cancelListening()
        #expect(service.state == .idle)
    }

    @Test func stopListeningReturnsEmptyWhenNotListening() async {
        let permissionManager = AudioPermissionManager()
        let service = SpeechRecognitionService(permissionManager: permissionManager)
        let result = await service.stopListening()
        #expect(result == "")
    }
}
