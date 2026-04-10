/// 文件说明：AudioPermissionManager，统一管理麦克风与语音识别权限。
import AVFoundation
import Speech

/// 音频相关权限状态。
enum AudioPermissionStatus: Sendable, Equatable {
    case notDetermined
    case authorized
    case denied
}

/// AudioPermissionManager：
/// 封装 AVCaptureDevice 和 SFSpeechRecognizer 的权限请求与状态查询。
@MainActor
@Observable
final class AudioPermissionManager: @unchecked Sendable {
    /// 麦克风权限状态
    private(set) var microphoneStatus: AudioPermissionStatus = .notDetermined
    /// 语音识别权限状态
    private(set) var speechRecognitionStatus: AudioPermissionStatus = .notDetermined

    /// 两项权限是否都已授权
    var isFullyAuthorized: Bool {
        microphoneStatus == .authorized && speechRecognitionStatus == .authorized
    }

    /// 检查当前权限状态（不触发系统弹窗）
    func checkPermissions() async {
        // 麦克风
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: microphoneStatus = .authorized
        case .denied, .restricted: microphoneStatus = .denied
        case .notDetermined: microphoneStatus = .notDetermined
        @unknown default: microphoneStatus = .notDetermined
        }

        // 语音识别
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: speechRecognitionStatus = .authorized
        case .denied, .restricted: speechRecognitionStatus = .denied
        case .notDetermined: speechRecognitionStatus = .notDetermined
        @unknown default: speechRecognitionStatus = .notDetermined
        }
    }

    /// 请求两项权限（依次弹窗）
    /// - Returns: 是否全部授权
    @discardableResult
    func requestPermissions() async -> Bool {
        // 1. 请求麦克风
        let micGranted = await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
        microphoneStatus = micGranted ? .authorized : .denied

        guard micGranted else { return false }

        // 2. 请求语音识别
        let speechGranted = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
        speechRecognitionStatus = speechGranted ? .authorized : .denied

        return isFullyAuthorized
    }
}
