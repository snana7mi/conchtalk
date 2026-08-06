/// 文件说明：SpecialToolHandler，拦截 suggest_agent_connection。
import Foundation

/// ChoiceInterceptResult：特殊 tool 拦截的处理结果。
nonisolated enum ChoiceInterceptResult: Sendable {
    case continueLoop(String)
    case exitLoop
}

/// SpecialToolInterceptResult：含构建消息的完整拦截结果。
nonisolated struct SpecialToolInterceptResult: Sendable {
    let interceptResult: ChoiceInterceptResult
    let constructedMessages: [Message]
}

/// SpecialToolHandler：
/// 拦截并处理 suggest_agent_connection，
/// 返回构建的消息和拦截结果，由外层协调器负责追加到会话历史和触发回调。
nonisolated enum SpecialToolHandler {

    // MARK: - suggest_agent_connection

    /// 处理 `suggest_agent_connection` 工具调用。
    /// - Parameters:
    ///   - toolCall: AI 发起的工具调用。
    ///   - reasoning: 本轮推理文本。
    ///   - callback: 向用户展示代理连接建议并等待决策的回调。
    /// - Returns: 拦截结果，包含构建的消息和继续/退出指令。
    static func handleSuggestAgentConnection(
        toolCall: ToolCall,
        reasoning: String?,
        callback: @Sendable (_ preferredAgent: String?, _ cwd: String?, _ directories: [String]?, _ homePath: String?) async -> AgentConnectionResult
    ) async -> SpecialToolInterceptResult {
        let args = (try? toolCall.decodedArguments()) ?? [:]
        let preferredAgent = args["agent"] as? String
        let reason = args["reason"] as? String ?? ""
        let cwd = (args["cwd"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let directories = args["directories"] as? [String]
        let homePath = args["home_path"] as? String

        var messages: [Message] = []

        // 初始命令消息（显示 AI 的建议）
        let cmdMsg = Message(role: .command, content: toolCall.explanation, toolCall: toolCall, toolOutput: reason, reasoningContent: reasoning)
        messages.append(cmdMsg)

        let result = await callback(preferredAgent, cwd, directories, homePath)

        switch result {
        case .confirmed:
            // 用户确认接入，UI 已进入直接模式，退出 agentic loop
            let doneOutput = "User confirmed and switched to direct conversation mode with coding agent. Session paused."
            let doneMsg = Message(role: .command, content: toolCall.explanation, toolCall: toolCall, toolOutput: doneOutput)
            messages.append(doneMsg)
            return SpecialToolInterceptResult(
                interceptResult: .exitLoop,
                constructedMessages: messages
            )
        case .cancelled:
            let cancelledOutput = "User cancelled agent connection. Continue helping the user normally."
            let cancelledMsg = Message(role: .command, content: toolCall.explanation, toolCall: toolCall, toolOutput: cancelledOutput)
            messages.append(cancelledMsg)
            return SpecialToolInterceptResult(
                interceptResult: .continueLoop(cancelledOutput),
                constructedMessages: messages
            )
        case .unsupported:
            // 该代理不支持 ACP 协议，告知用户无法接入
            let unsupportedOutput = "This agent is not available on the server or does not support ACP protocol. Agent connection is only possible via ACP — there is no alternative method. Inform the user that this agent cannot be connected, and suggest they install or configure the agent with ACP support on the server. Do NOT call suggest_agent_connection again for this agent."
            let unsupportedMsg = Message(role: .command, content: toolCall.explanation, toolCall: toolCall, toolOutput: unsupportedOutput)
            messages.append(unsupportedMsg)
            return SpecialToolInterceptResult(
                interceptResult: .continueLoop(unsupportedOutput),
                constructedMessages: messages
            )
        case .customPath:
            // 用户选择自定义路径，提示 AI 在对话中询问
            let customPathOutput = "User wants to specify a custom working directory path. Ask the user which directory they want to open the coding agent in. After they provide the path, call suggest_agent_connection again with the 'cwd' parameter set to the user's specified path."
            let customPathMsg = Message(role: .command, content: toolCall.explanation, toolCall: toolCall, toolOutput: customPathOutput)
            messages.append(customPathMsg)
            return SpecialToolInterceptResult(
                interceptResult: .continueLoop(customPathOutput),
                constructedMessages: messages
            )
        }
    }

    // MARK: - activate_skill

    /// 若 `activate_skill` 执行成功，构造对应的 skillLoaded 系统消息（否则返回 nil）。
    /// 把工具特定的输出解析从通用 agentic loop 中抽离（职责单一）；解析失败记 debug 日志，
    /// 而非旧实现里 `try?` 的完全静默——若 skill 工具改了输出格式，至少能在日志里看到。
    static func skillLoadedMessage(forToolName toolName: String, output: String) -> Message? {
        guard toolName == "activate_skill" else { return nil }
        guard let data = output.data(using: .utf8) else { return nil }
        do {
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                #if DEBUG
                print("[SpecialToolHandler] activate_skill 输出不是 JSON 对象，跳过 skillLoaded")
                #endif
                return nil
            }
            // status 非 activated（如激活失败）或缺 displayName 时不插入 skillLoaded（属正常分支）
            guard json["status"] as? String == "activated",
                  let displayName = json["displayName"] as? String else {
                return nil
            }
            return Message(role: .system, content: displayName, systemMessageType: .skillLoaded)
        } catch {
            #if DEBUG
            print("[SpecialToolHandler] activate_skill 输出 JSON 解析失败: \(error)")
            #endif
            return nil
        }
    }

}
