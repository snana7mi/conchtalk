/// 文件说明：SpeechRecognitionService，基于 SFSpeechRecognizer + AVAudioEngine 的语音识别实现。
import AVFoundation
import Speech

/// SpeechRecognitionService：
/// 管理音频采集、语音识别和静默检测的完整生命周期。
/// 使用 @Observable 驱动 UI 状态更新，音频回调在音频线程执行。
@MainActor
@Observable
final class SpeechRecognitionService: SpeechRecognitionProtocol {
    // MARK: - 公开状态

    /// 当前识别状态
    private(set) var state: SpeechRecognitionState = .idle

    /// 设备是否支持语音识别（不检查权限，权限在首次点击时请求）
    var isAvailable: Bool {
        SFSpeechRecognizer()?.isAvailable == true
    }

    // MARK: - 私有属性

    private let permissionManager: AudioPermissionManager
    private let silenceConfig: SilenceDetectionConfig

    private var audioEngine: AVAudioEngine?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var speechRecognizer: SFSpeechRecognizer?
    /// 静默检测状态
    private var recordingStart: Date?
    private var lastResultTime: Date?
    private var silenceTimer: Task<Void, Never>?
    private var finalText: String = ""
    /// 片段累积状态机（重置检测 + 确认文本累积），仅在 MainActor 上读写。
    private var segmentAccumulator = SpeechSegmentAccumulator()

    // MARK: - 初始化

    init(permissionManager: AudioPermissionManager, silenceConfig: SilenceDetectionConfig = SilenceDetectionConfig()) {
        self.permissionManager = permissionManager
        self.silenceConfig = silenceConfig
    }

    // MARK: - 公开方法

    func startListening(locale: Locale = .current) async throws {
        print("[Speech] startListening: permissionManager.isFullyAuthorized = \(permissionManager.isFullyAuthorized)")
        // 确保权限
        if !permissionManager.isFullyAuthorized {
            print("[Speech] requesting permissions...")
            let granted = await permissionManager.requestPermissions()
            print("[Speech] permissions granted: \(granted)")
            guard granted else {
                state = .error(String(localized: "Microphone or speech recognition permission denied", bundle: LanguageSettings.currentBundle))
                print("[Speech] permission denied, returning")
                return
            }
        }

        // 初始化识别器
        speechRecognizer = SFSpeechRecognizer(locale: locale)
        guard let speechRecognizer, speechRecognizer.isAvailable else {
            state = .error(String(localized: "Speech recognition is not available for this language", bundle: LanguageSettings.currentBundle))
            return
        }

        // 配置音频会话
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

        // 创建识别请求
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if speechRecognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        recognitionRequest = request

        // 配置音频引擎
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        // 重置状态
        recordingStart = Date()
        lastResultTime = nil
        silenceTimer?.cancel()
        finalText = ""
        segmentAccumulator.reset()
        state = .listening(partialText: "")

        // 安装音频 tap（仅送入识别器；捕获局部 request 常量，不经 self 跨线程读属性）
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
            request.append(buffer)
        }

        // 启动最大时长兜底
        let maxDuration = silenceConfig.maxDuration
        silenceTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(maxDuration))
            guard !Task.isCancelled else { return }
            print("[Speech] max duration (\(maxDuration)s) reached, auto-stopping")
            _ = await self?.stopListening()
        }

        // 启动识别任务。回调在系统私有队列触发：回调线程只取局部不可变值，
        // 状态读写整体 hop 到 MainActor，消除与 stopListening 的数据竞争。
        recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result.map { $0.bestTranscription.formattedString }
            let isFinal = result?.isFinal ?? false
            let callbackError = error
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let text {
                    print("[Speech] partial result: \"\(text)\", isFinal: \(isFinal)")
                    // 忽略空结果（endAudio() 后系统可能返回空的 isFinal）；已停止则忽略后续回调
                    if !text.isEmpty, case .listening = self.state {
                        self.finalText = self.segmentAccumulator.ingest(text)
                        self.state = .listening(partialText: self.finalText)
                        // 每次收到新结果，重置静默计时器
                        self.resetSilenceTimer()
                    }
                }
                if let callbackError {
                    print("[Speech] recognitionTask error: \(callbackError), code: \((callbackError as NSError).code)")
                    self.silenceTimer?.cancel()
                    // 取消 / 无语音 不算错误
                    let code = (callbackError as NSError).code
                    if code != 216 && code != 1110 {
                        self.state = .error(callbackError.localizedDescription)
                    } else {
                        self.stopAudioEngine()
                    }
                }
            }
        }

        // 启动引擎
        engine.prepare()
        try engine.start()
        audioEngine = engine
    }

    func stopListening() async -> String {
        guard case .listening = state else { return finalText }
        state = .finishing
        silenceTimer?.cancel()
        recognitionRequest?.endAudio()
        stopAudioEngine()
        let result = finalText
        state = .idle
        return result
    }

    func cancelListening() async {
        silenceTimer?.cancel()
        recognitionTask?.cancel()
        recognitionRequest?.endAudio()
        stopAudioEngine()
        finalText = ""
        state = .idle
    }

    // MARK: - 私有方法

    /// 重置静默计时器：每次收到新的识别结果时调用。
    /// 如果 silenceDuration 秒内没有新结果到达，自动停止录音。
    private func resetSilenceTimer() {
        silenceTimer?.cancel()
        let duration = silenceConfig.silenceDuration
        silenceTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            print("[Speech] no new results for \(duration)s, auto-stopping")
            _ = await self?.stopListening()
        }
    }

    /// 停止音频引擎并清理资源
    private func stopAudioEngine() {
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil
        recognitionRequest = nil
        recognitionTask = nil

        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
