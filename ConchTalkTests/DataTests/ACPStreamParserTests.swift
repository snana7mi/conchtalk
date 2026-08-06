/// 文件说明：ACPStreamParserTests，验证 ACP 流式事件增量解析的正确性。
import Testing
@testable import ConchTalk
import Foundation

@Suite("ACPStreamParser")
struct ACPStreamParserTests {
    @Test("解析单条完整事件行")
    func parseSingleCompleteLine() throws {
        var parser = ACPStreamParser()
        let event = AgentStreamEvent.thinking("hello")
        let line = try event.encodeToStreamLine()
        let results = parser.parse(chunk: line)
        #expect(results.count == 1)
        #expect(results[0] == event)
    }

    @Test("跨 chunk 断行：前半到达后不解析，累积完整后解析")
    func parseSplitAcrossChunks() throws {
        var parser = ACPStreamParser()
        let event = AgentStreamEvent.text("world")
        let line = try event.encodeToStreamLine()
        let mid = line.index(line.startIndex, offsetBy: line.count / 2)
        let part1 = String(line[..<mid])

        // 增量 chunk 模式：第一次传入前半段（不完整行）
        let r1 = parser.parse(chunk: part1)
        #expect(r1.isEmpty)
        // 第二次只传入新到达的后半段
        let r2 = parser.parse(chunk: String(line[mid...]))
        #expect(r2.count == 1)
        #expect(r2[0] == event)
    }

    @Test("连续多行一次到达")
    func parseMultipleLines() throws {
        var parser = ACPStreamParser()
        let e1 = AgentStreamEvent.thinking("a")
        let e2 = AgentStreamEvent.completed
        let text = try e1.encodeToStreamLine() + e2.encodeToStreamLine()
        let results = parser.parse(chunk: text)
        #expect(results.count == 2)
        #expect(results[0] == e1)
        #expect(results[1] == e2)
    }

    @Test("非 ACP 行被忽略")
    func ignoreNonACPLines() {
        var parser = ACPStreamParser()
        let results = parser.parse(chunk: "plain output\nanother line\n")
        #expect(results.isEmpty)
    }

    @Test("累积调用：每个字符只解析一次")
    func incrementalOffsetAdvances() throws {
        var parser = ACPStreamParser()
        let e1 = AgentStreamEvent.thinking("first")
        let e2 = AgentStreamEvent.text("second")
        let line1 = try e1.encodeToStreamLine()
        let line2 = try e2.encodeToStreamLine()

        // 第一次：完整 line1
        let r1 = parser.parse(chunk: line1)
        #expect(r1.count == 1)
        // 第二次：只传入新到达的 line2
        let r2 = parser.parse(chunk: line2)
        #expect(r2.count == 1)
        #expect(r2[0] == e2)
    }

    @Test("空字符串不崩溃")
    func emptyInput() {
        var parser = ACPStreamParser()
        let results = parser.parse(chunk: "")
        #expect(results.isEmpty)
    }

    @Test("reset 后重新从头解析")
    func resetClearsOffset() throws {
        var parser = ACPStreamParser()
        let event = AgentStreamEvent.thinking("x")
        let line = try event.encodeToStreamLine()
        _ = parser.parse(chunk: line)
        parser.reset()
        let results = parser.parse(chunk: line)
        #expect(results.count == 1)
    }
}
