/// 文件说明：TokenEstimatorTests，覆盖 TokenEstimator 的核心 token 估算逻辑。
import Testing
@testable import ConchTalk
import Foundation

@Suite("TokenEstimator")
struct TokenEstimatorTests {
    let estimator = TokenEstimator()

    @Test("空字符串返回 0")
    func emptyString() {
        #expect(estimator.estimateTokens("") == 0)
    }

    @Test("纯 ASCII 文本：每 4 字符约 1 token")
    func pureASCII() {
        // 16 字符 ASCII → 4 tokens
        let result = estimator.estimateTokens("Hello World 1234")
        #expect(result == 4)
    }

    @Test("短 ASCII 文本：至少 1 token")
    func shortASCII() {
        // 3 字符 → max(3/4, 1) = 1
        let result = estimator.estimateTokens("Hi!")
        #expect(result == 1)
    }

    @Test("纯 CJK 文本：每字符 2 token")
    func pureCJK() {
        // 3 个 CJK 字符 → 6 tokens
        let result = estimator.estimateTokens("你好世")
        #expect(result == 6)
    }

    @Test("CJK 与 ASCII 混合：分段计算")
    func mixedCJKAndASCII() {
        // "Hello" = 5 ASCII (max(5/4,1) = 1)，"你好" = 2 CJK (4 tokens)，" world" = 6 ASCII (max(6/4,1) = 1)
        // 总计 6 tokens
        let result = estimator.estimateTokens("Hello你好 world")
        #expect(result == 6)
    }

    @Test("单个 CJK 字符返回 2")
    func singleCJK() {
        #expect(estimator.estimateTokens("中") == 2)
    }

    @Test("CJK 扩展 A 范围（U+3400）也被识别")
    func cjkExtendedA() {
        // U+3400 = 㐀，CJK Unified Ideographs Extension A
        let char = "\u{3400}"
        #expect(estimator.estimateTokens(char) == 2)
    }

    @Test("日文标点（U+3000 范围）被识别为 CJK")
    func japanesePunctuation() {
        // U+3000 = 　（全角空格）
        let char = "\u{3000}"
        #expect(estimator.estimateTokens(char) == 2)
    }
}
