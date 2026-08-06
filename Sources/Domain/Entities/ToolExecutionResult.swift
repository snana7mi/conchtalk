/// 文件说明：ToolExecutionResult，定义工具执行后的标准结果模型。
import Foundation

/// ToolExecutionResult：
/// 统一承载工具输出内容与执行状态，作为工具层返回值在上游传播。
nonisolated struct ToolExecutionResult: Sendable {
    let output: String
    let isSuccess: Bool

    /// 工具输出硬上限（字符数）。约 8K 字符 ≈ 2K tokens，多轮 agentic loop 下控制上下文开销。
    private static let maxOutputLength = 8_000
    /// 截断时保留的头部字符数（展示命令结构、表头等开头信息）。
    private static let headLength = 2_000
    /// 截断时保留的尾部字符数（展示错误信息、最终状态等末尾信息）。
    private static let tailLength = 6_000

    /// 初始化工具执行结果。
    /// - Parameters:
    ///   - output: 工具输出文本（超过上限时保留头部 + 尾部，中间部分省略）。
    ///   - isSuccess: 执行是否成功（默认 `true`）。
    init(output: String, isSuccess: Bool = true) {
        if output.count > Self.maxOutputLength {
            let head = String(output.prefix(Self.headLength))
            let tail = String(output.suffix(Self.tailLength))
            let omitted = output.count - Self.headLength - Self.tailLength
            self.output = head + "\n\n... [\(omitted) chars omitted, \(output.count) total] ...\n\n" + tail
        } else {
            self.output = output
        }
        self.isSuccess = isSuccess
    }
}
