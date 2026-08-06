/// 文件说明：SpeechSegmentAccumulator，语音识别片段重置检测与确认文本累积的纯状态机。

/// SpeechSegmentAccumulator：
/// 吸收 SFSpeechRecognizer 的 partial result，检测「片段重置」（用户停顿后识别器
/// 可能只返回新片段）并把前一片段提交到确认文本。纯值类型，无共享可变状态，可独立单测。
nonisolated struct SpeechSegmentAccumulator {
    /// 已确认的前序片段累积文本。
    private(set) var confirmedText = ""
    /// 当前片段中最近一次 partial result 的文本。
    private(set) var lastPartialText = ""

    /// 吸收一次 partial result，返回合并后的全文（confirmed + 当前片段）。
    /// 片段重置判定：文本长度骤降（≤ 前次一半）且不是前次结果的前缀。
    mutating func ingest(_ text: String) -> String {
        if !lastPartialText.isEmpty
            && text.count <= lastPartialText.count / 2
            && !lastPartialText.hasPrefix(text) {
            confirmedText += lastPartialText
        }
        lastPartialText = text
        return confirmedText + text
    }

    /// 清空全部累积状态（开始新一轮录音时调用）。
    mutating func reset() {
        confirmedText = ""
        lastPartialText = ""
    }
}
