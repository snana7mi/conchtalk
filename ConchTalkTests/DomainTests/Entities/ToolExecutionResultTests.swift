/// 文件说明：ToolExecutionResultTests，测试 ToolExecutionResult 的截断策略与基本行为。
import Testing
@testable import ConchTalk
import Foundation

@Suite("ToolExecutionResult Entity")
struct ToolExecutionResultTests {

    // MARK: - 默认值

    @Test("Default isSuccess is true")
    func defaultIsSuccess() {
        let result = ToolExecutionResult(output: "some output")
        #expect(result.isSuccess == true)
        #expect(result.output == "some output")
    }

    // MARK: - 显式赋值

    @Test("Explicit isSuccess false")
    func explicitIsSuccessFalse() {
        let result = ToolExecutionResult(output: "error occurred", isSuccess: false)
        #expect(result.isSuccess == false)
        #expect(result.output == "error occurred")
    }

    // MARK: - 截断策略

    @Test("短输出不截断")
    func shortOutputNotTruncated() {
        let output = String(repeating: "x", count: 8_000)
        let result = ToolExecutionResult(output: output)
        #expect(result.output == output)
        #expect(result.output.count == 8_000)
    }

    @Test("超限输出使用 head+tail 截断")
    func longOutputTruncatedWithHeadAndTail() {
        // 构造 10_000 字符的输出：前 3000 个 "H"，中间 4000 个 "M"，后 3000 个 "T"
        let head = String(repeating: "H", count: 3_000)
        let middle = String(repeating: "M", count: 4_000)
        let tail = String(repeating: "T", count: 3_000)
        let output = head + middle + tail
        #expect(output.count == 10_000)

        let result = ToolExecutionResult(output: output)

        // 截断后应保留前 2000 字符（全是 H）
        #expect(result.output.hasPrefix(String(repeating: "H", count: 2_000)))
        // 截断后应保留后 6000 字符（1000 个 M + 3000 个 H 的尾部？不对，让我重新算）
        // 后 6000 个字符 = output 的 [4000..<10000] = 4000 个 M 的后 1000 个 + 3000 个 T... 不对
        // output = HHH...H(3000) + MMM...M(4000) + TTT...T(3000)
        // suffix(6000) = output[4000..<10000] = M(1000) + T(3000)... 不对，4000+3000=7000
        // suffix(6000) 从 index 4000 开始 = M*1000 不对
        // 10000 - 6000 = 4000, 所以从 index 4000 开始
        // index 0-2999: H, 3000-6999: M, 7000-9999: T
        // index 4000-9999 = M*3000 + T*3000
        #expect(result.output.hasSuffix(String(repeating: "T", count: 3_000)))

        // 包含省略标记
        #expect(result.output.contains("chars omitted"))
        #expect(result.output.contains("10000 total"))
    }

    @Test("截断后总长度小于原始输出")
    func truncatedOutputIsShorter() {
        let output = String(repeating: "A", count: 20_000)
        let result = ToolExecutionResult(output: output)

        // head(2000) + separator + tail(6000) 应远小于 20000
        #expect(result.output.count < 10_000)
        #expect(result.output.count > 8_000) // 至少 head + tail = 8000
    }

    @Test("恰好超限一个字符也触发截断")
    func boundaryTruncation() {
        let output = String(repeating: "B", count: 8_001)
        let result = ToolExecutionResult(output: output)
        #expect(result.output.contains("chars omitted"))
    }

    @Test("截断保留头部内容完整性")
    func headContentPreserved() {
        let header = "=== Command Output ===\nLine 1\nLine 2\n"
        let filler = String(repeating: "x\n", count: 10_000)
        let output = header + filler
        let result = ToolExecutionResult(output: output)

        // 头部前缀应完整保留
        #expect(result.output.hasPrefix("=== Command Output ===\nLine 1\nLine 2\n"))
    }

    @Test("截断保留尾部错误信息")
    func tailContentPreserved() {
        let filler = String(repeating: "x\n", count: 10_000)
        let errorTail = "\nERROR: Build failed with 3 errors\nexit code 1\n"
        let output = filler + errorTail
        let result = ToolExecutionResult(output: output)

        // 尾部错误信息应完整保留
        #expect(result.output.hasSuffix(errorTail))
    }
}
