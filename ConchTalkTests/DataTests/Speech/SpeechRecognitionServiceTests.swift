/// 文件说明：SpeechRecognitionServiceTests，验证语音识别服务的状态管理与静默检测逻辑。
import Testing
@testable import ConchTalk
import Foundation
import Speech

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

    @Test func isAvailableReflectsRecognizerAvailability() {
        let permissionManager = AudioPermissionManager()
        let service = SpeechRecognitionService(permissionManager: permissionManager)
        #expect(service.isAvailable == (SFSpeechRecognizer()?.isAvailable == true))
    }

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
