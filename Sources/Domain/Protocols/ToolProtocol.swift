/// 文件说明：ToolProtocol，定义 AI 工具调用的统一契约与安全分级。
import Foundation

/// SafetyLevel：定义工具调用在执行前的安全决策级别。
enum SafetyLevel: Sendable {
    case safe               // 可直接执行，不需要用户确认
    case needsConfirmation  // 需要弹窗确认后再执行
    case forbidden          // 明确禁止执行
}

/// ToolProtocol：
/// 所有 AI 可调用工具的统一接口，负责声明工具元信息、参数结构、安全策略与执行逻辑。
protocol ToolProtocol: Sendable {
    /// 工具唯一名称（如 `execute_ssh_command`），用于模型函数调用匹配。
    var name: String { get }
    /// 工具用途说明，会注入系统提示词帮助模型正确选工具。
    var description: String { get }
    /// 函数调用参数的 JSON Schema（OpenAI tools 格式）。
    var parametersSchema: [String: Any] { get }
    /// 根据本次参数评估安全级别。
    /// - Parameter arguments: 本次工具调用参数。
    /// - Returns: 对应的安全级别（直接执行/确认/禁止）。
    func validateSafety(arguments: [String: Any]) -> SafetyLevel
    /// 执行工具逻辑并返回标准化结果。
    /// - Parameters:
    ///   - arguments: 本次工具调用参数。
    ///   - sshClient: 远端命令执行客户端。
    /// - Returns: 工具执行结果（文本输出）。
    /// - Throws: 参数缺失、参数非法或远端执行失败时抛出。
    func execute(arguments: [String: Any], sshClient: SSHClientProtocol) async throws -> ToolExecutionResult
}
