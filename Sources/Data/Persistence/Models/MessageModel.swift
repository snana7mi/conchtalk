/// 文件说明：MessageModel，定义消息在 SwiftData 中的持久化结构与兼容字段。
import Foundation
import SwiftData

/// MessageModel：
/// 消息持久化模型，兼容历史 `SSHCommand` 字段并支持新 `ToolCall` 结构。
@Model
final class MessageModel {
    @Attribute(.unique) var id: UUID
    var roleRaw: String
    var content: String
    var timestamp: Date
    var commandJSON: Data?     // Legacy: encoded SSHCommand (read-only for backward compat)
    var commandOutput: String? // Legacy field name, also used by new messages
    var toolCallJSON: Data?    // New: encoded ToolCall
    var reasoningContent: String? // AI reasoning/thinking chain

    var conversation: ConversationModel?

    /// 初始化消息持久化模型。
    /// - Parameters:
    ///   - id: 消息标识。
    ///   - roleRaw: 角色原始值。
    ///   - content: 消息正文。
    ///   - timestamp: 消息时间戳。
    ///   - commandJSON: 旧版命令结构（兼容字段）。
    ///   - commandOutput: 命令/工具输出文本。
    ///   - toolCallJSON: 新版工具调用结构。
    ///   - reasoningContent: 推理链文本。
    init(id: UUID = UUID(), roleRaw: String, content: String, timestamp: Date = Date(), commandJSON: Data? = nil, commandOutput: String? = nil, toolCallJSON: Data? = nil, reasoningContent: String? = nil) {
        self.id = id
        self.roleRaw = roleRaw
        self.content = content
        self.timestamp = timestamp
        self.commandJSON = commandJSON
        self.commandOutput = commandOutput
        self.toolCallJSON = toolCallJSON
        self.reasoningContent = reasoningContent
    }

    /// 转换为领域层 `Message` 实体。
    /// - Returns: 领域消息对象。
    /// - Note:
    ///   - 优先读取 `toolCallJSON`（新格式）。
    ///   - 若不存在则尝试把 `commandJSON`（旧格式）包装为 `ToolCall` 兼容返回。
    func toDomain() -> Message {
        let role = Message.MessageRole(rawValue: roleRaw) ?? .system

        // Try new toolCallJSON first
        if let data = toolCallJSON, let toolCall = try? JSONDecoder().decode(ToolCall.self, from: data) {
            return Message(id: id, role: role, content: content, timestamp: timestamp, toolCall: toolCall, toolOutput: commandOutput, reasoningContent: reasoningContent, isLoading: false)
        }

        // Fallback: legacy SSHCommand → wrap as ToolCall
        if let data = commandJSON, let sshCommand = try? JSONDecoder().decode(SSHCommand.self, from: data) {
            let argsJSON = data // SSHCommand JSON is already the arguments
            let toolCall = ToolCall(
                id: "legacy_\(id.uuidString.prefix(8))",
                toolName: "execute_ssh_command",
                argumentsJSON: argsJSON,
                explanation: sshCommand.explanation
            )
            return Message(id: id, role: role, content: content, timestamp: timestamp, toolCall: toolCall, toolOutput: commandOutput, reasoningContent: reasoningContent, isLoading: false)
        }

        return Message(id: id, role: role, content: content, timestamp: timestamp, toolCall: nil, toolOutput: nil, reasoningContent: reasoningContent, isLoading: false)
    }

    /// 从领域层 `Message` 构建持久化模型。
    /// - Parameter message: 领域消息对象。
    /// - Returns: 对应的持久化模型实例。
    /// - Note: 新写入不再填充旧 `commandJSON` 字段，仅保留读取兼容。
    static func fromDomain(_ message: Message) -> MessageModel {
        var toolCallData: Data? = nil
        if let tc = message.toolCall {
            toolCallData = try? JSONEncoder().encode(tc)
        }
        return MessageModel(
            id: message.id,
            roleRaw: message.role.rawValue,
            content: message.content,
            timestamp: message.timestamp,
            commandJSON: nil,  // No longer write legacy field
            commandOutput: message.toolOutput,
            toolCallJSON: toolCallData,
            reasoningContent: message.reasoningContent
        )
    }
}
