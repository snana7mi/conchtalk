/// 文件说明：LineDiffTests，验证行级 LCS Diff 的增删与上下文。
import Testing
@testable import ConchTalk

@Suite("LineDiff")
struct LineDiffTests {
    @Test("无变化时全部是 context")
    func unchanged() {
        let r = LineDiff.diff(old: ["a", "b"], new: ["a", "b"])
        #expect(r == [.context("a"), .context("b")])
    }

    @Test("纯新增")
    func added() {
        let r = LineDiff.diff(old: ["a"], new: ["a", "b"])
        #expect(r == [.context("a"), .added("b")])
    }

    @Test("纯删除")
    func removed() {
        let r = LineDiff.diff(old: ["a", "b"], new: ["a"])
        #expect(r == [.context("a"), .removed("b")])
    }

    @Test("替换中间行")
    func replacedMiddle() {
        let r = LineDiff.diff(old: ["a", "x", "c"], new: ["a", "y", "c"])
        #expect(r == [.context("a"), .removed("x"), .added("y"), .context("c")])
    }

    @Test("空到非空")
    func emptyToContent() {
        let r = LineDiff.diff(old: [], new: ["a", "b"])
        #expect(r == [.added("a"), .added("b")])
    }
}
