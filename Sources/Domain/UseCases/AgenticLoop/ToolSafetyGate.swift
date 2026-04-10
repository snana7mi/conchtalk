/// 文件说明：ToolSafetyGate，工具安全分级校验与权限映射后决定执行/确认/禁止。
import Foundation

/// ToolGateResult：安全门评估结果。
nonisolated enum ToolGateResult: Sendable {
    /// 工具已成功执行，附带结果和是否为写操作标记。
    case executed(ToolExecutionResult, hadWrite: Bool)
    /// 工具执行过程中抛出异常。
    case executionError(String)
    /// 用户拒绝了需要确认的操作。
    case denied
    /// 操作被安全策略禁止。
    case forbidden
}

/// ToolSafetyGate：
/// 工具安全分级校验 + permission level 映射 + 执行。
/// 职责单一：只负责"能不能执行"的决策与执行，不涉及消息构建和后续 AI 交互。
nonisolated enum ToolSafetyGate {

    /// 评估工具安全级别并执行（或拒绝/禁止）。
    /// - Parameters:
    ///   - toolCall: AI 发起的工具调用。
    ///   - tool: 对应的工具实例。
    ///   - arguments: 解码后的调用参数。
    ///   - sshClient: SSH 客户端，供工具执行远端命令。
    ///   - permissionLevel: 当前生效的权限等级。
    ///   - onConfirmation: 需要用户确认时的回调。
    ///   - onOutput: 工具实时输出回调（累积文本）。
    ///   - onAgentEvents: ACP 编码代理流式事件批量回调。
    /// - Returns: 安全门评估结果。
    static func evaluate(
        toolCall: ToolCall,
        tool: ToolProtocol,
        arguments: [String: Any],
        sshClient: SSHClientProtocol,
        permissionLevel: PermissionLevel,
        onConfirmation: @Sendable (ToolCall) async -> CommandApproval,
        onOutput: @MainActor @escaping @Sendable (String) -> Void,
        onAgentEvents: @MainActor @escaping @Sendable ([AgentStreamEvent]) -> Void
    ) async -> ToolGateResult {
        let rawSafety = tool.validateSafety(arguments: arguments)
        let effectiveSafety = permissionLevel.effectiveSafetyLevel(rawSafety)

        switch effectiveSafety {
        case .safe:
            await onOutput("")  // 重置实时输出
            do {
                let result = try await StreamingToolExecutor.execute(
                    tool: tool, arguments: arguments, sshClient: sshClient,
                    onOutput: onOutput, onAgentEvents: onAgentEvents
                )
                return .executed(result, hadWrite: false)
            } catch {
                let errorOutput = "ERROR: \(error.localizedDescription)"
                await onOutput(errorOutput)
                return .executionError(errorOutput)
            }

        case .needsConfirmation:
            let approval = await onConfirmation(toolCall)
            guard approval == .approved else {
                return .denied
            }
            await onOutput("")  // 重置实时输出
            do {
                let result = try await StreamingToolExecutor.execute(
                    tool: tool, arguments: arguments, sshClient: sshClient,
                    onOutput: onOutput, onAgentEvents: onAgentEvents
                )
                return .executed(result, hadWrite: true)
            } catch {
                let errorOutput = "ERROR: \(error.localizedDescription)"
                await onOutput(errorOutput)
                return .executionError(errorOutput)
            }

        case .forbidden:
            return .forbidden
        }
    }
}
