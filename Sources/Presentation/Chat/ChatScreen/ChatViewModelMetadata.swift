/// 文件说明：ChatViewModelMetadata，承载导航标题、系统消息与确认文案格式化。
import Foundation

extension ChatViewModel {
    /// 导航栏标题：直连模式显示 agent 名，普通模式显示服务器名。
    var navigationTitle: String {
        if let agentName = directModePresentation.agentName {
            return agentName
        }
        return server.name.isEmpty ? server.host : server.name
    }

    /// 追加一条系统消息到消息列表并持久化。
    func appendSystemMessage(_ text: String, type: Message.SystemMessageType) {
        let timestamp = Date.now.formatted(date: .abbreviated, time: .standard)
        let msg = Message(role: .system, content: text + " (\(timestamp))", systemMessageType: type)
        messages.append(msg)
        Task { [store, serverID] in
            try? await store.addMessage(msg, toServer: serverID)
        }
    }

    /// confirmationMessage：生成待确认工具调用的展示文案。
    func confirmationMessage(for toolCall: ToolCall) -> String {
        let args = try? toolCall.decodedArguments()

        switch toolCall.toolName {
        case "execute_ssh_command":
            let cmd = args?["command"] as? String ?? ""
            return "\(toolCall.explanation)\n\n$ \(cmd)"
        case "write_file":
            let path = args?["path"] as? String ?? ""
            let append = args?["append"] as? Bool ?? false
            let action = append
                ? String(localized: "Append to", bundle: LanguageSettings.currentBundle)
                : String(localized: "Write to", bundle: LanguageSettings.currentBundle)
            return "\(toolCall.explanation)\n\n\(action): \(path)"
        default:
            return toolCall.explanation
        }
    }
}
