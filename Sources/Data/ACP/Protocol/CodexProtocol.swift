/// 文件说明：CodexProtocol，Codex CLI app-server 的 JSON-RPC 消息类型定义。

import Foundation

// MARK: - 从 Codex stdout 接收的消息

/// CodexRPCMessage：Codex app-server 输出的 JSON-RPC 消息。
/// 包含 RPC 响应（有 id）和通知（有 method）两种。
nonisolated enum CodexRPCMessage: Decodable, Sendable {
    case response(CodexRPCResponse)
    case notification(CodexNotification)

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let hasId = container.contains(.id)
        let hasMethod = container.contains(.method)

        if hasId && !hasMethod {
            self = .response(try CodexRPCResponse(from: decoder))
        } else if hasMethod {
            self = .notification(try CodexNotification(from: decoder))
        } else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: [], debugDescription: "CodexRPCMessage: neither response nor notification"
            ))
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, method
    }
}

/// CodexRPCResponse：JSON-RPC 响应。
nonisolated struct CodexRPCResponse: Decodable, Sendable {
    let id: Int
    let result: AnyCodableJSON?
    let error: CodexRPCError?
}

nonisolated struct CodexRPCError: Decodable, Sendable {
    let code: Int?
    let message: String?
}

/// CodexNotification：JSON-RPC 通知（无 id，有 method）。
nonisolated struct CodexNotification: Decodable, Sendable {
    let method: String
    let params: AnyCodableJSON?

    /// 解码 item/started 和 item/completed 的 item 参数。
    func decodeItemParams() throws -> CodexItem? {
        guard let params else { return nil }
        let data = try JSONEncoder().encode(params)
        let wrapper = try JSONDecoder().decode(CodexItemWrapper.self, from: data)
        return wrapper.item
    }

    /// 解码 item/agentMessage/delta 的 delta 文本。
    func decodeDelta() throws -> String? {
        guard let params else { return nil }
        let data = try JSONEncoder().encode(params)
        let wrapper = try JSONDecoder().decode(CodexDeltaWrapper.self, from: data)
        return wrapper.delta
    }

    /// 解码 turn/completed 的 turn 状态。
    func decodeTurnStatus() throws -> String? {
        guard let params else { return nil }
        let data = try JSONEncoder().encode(params)
        let wrapper = try JSONDecoder().decode(CodexTurnWrapper.self, from: data)
        return wrapper.turn?.status
    }

    /// 解码 thread/start 的 thread ID。
    func decodeThreadId() throws -> String? {
        guard let params else { return nil }
        let data = try JSONEncoder().encode(params)
        let wrapper = try JSONDecoder().decode(CodexThreadWrapper.self, from: data)
        return wrapper.thread?.id ?? wrapper.threadId
    }
}

// MARK: - Notification 内部结构

nonisolated struct CodexItemWrapper: Decodable, Sendable {
    let item: CodexItem?
}

/// CodexItem：Codex 流式通知中的 item。
nonisolated struct CodexItem: Decodable, Sendable {
    let type: String
    let id: String?
    let text: String?
    let phase: String?
    let command: String?
    let query: String?
    let aggregatedOutput: String?
    let content: [CodexItemContent]?
}

nonisolated struct CodexItemContent: Decodable, Sendable {
    let type: String?
    let text: String?
}

nonisolated struct CodexDeltaWrapper: Decodable, Sendable {
    let delta: String?
}

nonisolated struct CodexTurnWrapper: Decodable, Sendable {
    let turn: CodexTurnInfo?
}

nonisolated struct CodexTurnInfo: Decodable, Sendable {
    let id: String?
    let status: String?
}

nonisolated struct CodexThreadWrapper: Decodable, Sendable {
    let thread: CodexThreadInfo?
    let threadId: String?
}

nonisolated struct CodexThreadInfo: Decodable, Sendable {
    let id: String?
}

// MARK: - 写入 Codex stdin 的请求

/// CodexRPCRequest：发送给 Codex app-server 的 JSON-RPC 请求。
nonisolated struct CodexRPCRequest: Encodable, Sendable {
    let jsonrpc = "2.0"
    let id: Int
    let method: String
    let params: AnyCodableJSON?

    init(id: Int, method: String, params: AnyCodableJSON? = nil) {
        self.id = id
        self.method = method
        self.params = params
    }

    /// 便捷构造：从 [String: AnyCodableJSON] 字典创建。
    init(id: Int, method: String, params: [String: AnyCodableJSON]) {
        self.id = id
        self.method = method
        self.params = .object(params)
    }
}

/// 便捷扩展：简化常见请求的构造。
extension CodexRPCRequest {
    static func initialize(id: Int) -> CodexRPCRequest {
        CodexRPCRequest(id: id, method: "initialize", params: [
            "clientInfo": .object(["name": .string("ConchTalk"), "version": .string("1.0.0")]),
            "capabilities": .object(["experimentalApi": .bool(true)])
        ])
    }

    static func threadStart(id: Int, cwd: String) -> CodexRPCRequest {
        CodexRPCRequest(id: id, method: "thread/start", params: ["cwd": .string(cwd)])
    }

    static func turnStart(
        id: Int,
        threadId: String,
        text: String,
        model: String? = nil,
        collaborationMode: String? = nil
    ) -> CodexRPCRequest {
        var params: [String: AnyCodableJSON] = [
            "threadId": .string(threadId),
            "input": .array([.object(["type": .string("text"), "text": .string(text)])])
        ]
        if let model { params["model"] = .string(model) }
        if let collaborationMode { params["collaborationMode"] = .string(collaborationMode) }
        return CodexRPCRequest(id: id, method: "turn/start", params: params)
    }

    static func turnInterrupt(id: Int, threadId: String) -> CodexRPCRequest {
        CodexRPCRequest(id: id, method: "turn/interrupt", params: ["threadId": .string(threadId)])
    }
}
