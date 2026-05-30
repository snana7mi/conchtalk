/// 文件说明：AgentStreamEvent，编码代理流式输出的事件类型。

import Foundation
@preconcurrency import ACPModel

/// AgentStreamEvent：ACP 直连模式流式输出的结构化事件。
/// 通过 `[ACP]` 前缀 + JSON 编码传输，ChatViewModel 解码后渲染结构化卡片。
nonisolated enum AgentStreamEvent: Codable, Sendable, Equatable {
    case agentConnected(name: String)
    case thinking(String)
    case text(String)
    case toolCall(name: String, arguments: String, status: String)
    case toolResult(name: String, result: String)
    case plan([AgentPlanEntry])
    case completed

    /// 编码为带 [ACP] 前缀的字符串，用于通过 ToolProtocol 的 String 流传输。
    /// 末尾追加换行符，确保 TaskExecutionCoordinator 中按行分割时能正确解析。
    func encodeToStreamLine() throws -> String {
        let data = try JSONEncoder().encode(self)
        guard let json = String(data: data, encoding: .utf8) else {
            throw ACPConnectionError.protocolError("Failed to encode AgentStreamEvent")
        }
        return "[ACP]" + json + "\n"
    }

    /// 从带 [ACP] 前缀的字符串解码。
    static func decodeFromStreamLine(_ line: String) -> AgentStreamEvent? {
        guard line.hasPrefix("[ACP]") else { return nil }
        let json = String(line.dropFirst(5))
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(AgentStreamEvent.self, from: data)
    }

    /// 从 ACPModel SessionUpdate 转换为内部 AgentStreamEvent。
    /// 返回 nil 表示忽略该更新（如 usage_update）。
    static func from(_ update: SessionUpdate) -> AgentStreamEvent? {
        switch update {
        case .agentMessageChunk(let content):
            if case .text(let textContent) = content {
                return textContent.text.isEmpty ? nil : .text(textContent.text)
            }
            return nil

        case .agentThoughtChunk(let content):
            if case .text(let textContent) = content {
                return textContent.text.isEmpty ? nil : .thinking(textContent.text)
            }
            return nil

        case .userMessageChunk:
            return nil

        case .toolCall(let tc):
            return .toolCall(
                name: tc.title ?? tc.kind?.rawValue ?? "tool",
                arguments: "",
                status: tc.status?.rawValue ?? "pending"
            )

        case .toolCallUpdate(let details):
            let status = details.status?.rawValue ?? "completed"
            let name = details.title ?? details.toolCallId
            if status == "completed" || status == "failed" {
                // 提取 content 中的文本结果
                let resultText = details.content?.compactMap { c -> String? in
                    if case .content(let block) = c, case .text(let t) = block {
                        return t.text
                    }
                    return nil
                }.joined() ?? ""
                return .toolResult(name: name, result: resultText)
            }
            return .toolCall(name: name, arguments: "", status: status)

        case .plan(let plan):
            let entries = plan.entries.map {
                AgentPlanEntry(title: $0.content, status: $0.status.rawValue)
            }
            return .plan(entries)

        case .availableCommandsUpdate, .currentModeUpdate, .configOptionUpdate,
             .sessionInfoUpdate, .usageUpdate:
            return nil
        }
    }
}

/// AgentPlanEntry：代理执行计划中的步骤（UI 展示用）。
nonisolated struct AgentPlanEntry: Codable, Sendable, Equatable {
    let title: String
    let status: String?
}
