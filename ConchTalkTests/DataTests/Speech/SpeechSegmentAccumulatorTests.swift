/// 文件说明：SpeechSegmentAccumulatorTests，验证语音片段累积纯状态机的提交与重置逻辑。
import Testing
@testable import ConchTalk

@Suite("SpeechSegmentAccumulator")
struct SpeechSegmentAccumulatorTests {

    @Test("文本增长时全文累积且不提交片段")
    func ingest_growingText_returnsAccumulated() {
        var accumulator = SpeechSegmentAccumulator()
        #expect(accumulator.ingest("你好") == "你好")
        #expect(accumulator.ingest("你好世界") == "你好世界")
        #expect(accumulator.confirmedText.isEmpty)
    }

    @Test("片段重置时提交前一片段")
    func ingest_segmentReset_commitsPreviousSegment() {
        var accumulator = SpeechSegmentAccumulator()
        _ = accumulator.ingest("你好世界今天")
        // 长度骤降（1 <= 6/2）且非前缀 → 提交前一片段"你好世界今天"
        let merged = accumulator.ingest("新")
        #expect(merged == "你好世界今天新")
        #expect(accumulator.confirmedText == "你好世界今天")
    }

    @Test("新文本是旧文本前缀时不误判提交")
    func ingest_prefixShrink_doesNotCommit() {
        var accumulator = SpeechSegmentAccumulator()
        _ = accumulator.ingest("你好世界今天")
        // "你好"长度虽骤降（2 <= 3）但是前缀 → 不提交
        let merged = accumulator.ingest("你好")
        #expect(merged == "你好")
        #expect(accumulator.confirmedText.isEmpty)
    }

    @Test("reset 清空全部状态")
    func reset_clearsAllState() {
        var accumulator = SpeechSegmentAccumulator()
        _ = accumulator.ingest("你好世界")
        accumulator.reset()
        #expect(accumulator.confirmedText.isEmpty)
        #expect(accumulator.lastPartialText.isEmpty)
        #expect(accumulator.ingest("新开始") == "新开始")
    }
}
