/// 文件说明：ToolExecutionResult，定义工具执行后的标准结果模型。
import Foundation

/// ToolExecutionResult：
/// 统一承载工具输出内容与执行状态，作为工具层返回值在上游传播。
nonisolated struct ToolExecutionResult: Sendable {
    let output: String
    let isSuccess: Bool

    /// 初始化工具执行结果。
    /// - Parameters:
    ///   - output: 工具输出文本。
    ///   - isSuccess: 执行是否成功（默认 `true`）。
    init(output: String, isSuccess: Bool = true) {
        self.output = output
        self.isSuccess = isSuccess
    }
}
