/// 文件说明：CodexProtocol，Codex CLI app-server 的 JSON-RPC 消息类型定义。

import Foundation

// MARK: - 从 Codex stdout 接收的消息

/// CodexRPCMessage：Codex app-server 输出的 JSON-RPC 消息。
/// 三种形态（见 openai/codex `app-server-protocol/src/rpc.rs`）：
/// - 响应：有 id、无 method（对客户端请求的回复）；
/// - 服务端请求：同时有 id 和 method（如命令/文件修改审批），客户端必须按 id 回复；
/// - 通知：有 method、无 id。
nonisolated enum CodexRPCMessage: Decodable, Sendable {
    case response(CodexRPCResponse)
    case request(CodexServerRequest)
    case notification(CodexNotification)

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let hasId = container.contains(.id)
        let hasMethod = container.contains(.method)

        if hasId && hasMethod {
            self = .request(try CodexServerRequest(from: decoder))
        } else if hasId {
            self = .response(try CodexRPCResponse(from: decoder))
        } else if hasMethod {
            self = .notification(try CodexNotification(from: decoder))
        } else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: [], debugDescription: "CodexRPCMessage: neither response, request nor notification"
            ))
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, method
    }
}

/// CodexRequestId：JSON-RPC 请求 ID，Codex 端定义为整数或字符串（untagged）。
/// 回复时必须原样回传，不能经 AnyCodableJSON 的 Double 中转（会变成浮点数）。
nonisolated enum CodexRequestId: Codable, Sendable, Equatable {
    case int(Int)
    case string(String)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let i = try? container.decode(Int.self) {
            self = .int(i)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .int(let i): try container.encode(i)
        case .string(let s): try container.encode(s)
        }
    }
}

/// CodexServerRequest：Codex app-server 发给客户端的请求（有 id + method），需要回复。
nonisolated struct CodexServerRequest: Decodable, Sendable {
    let id: CodexRequestId
    let method: String
    let params: AnyCodableJSON?

    /// 读取 params 中的字符串字段。
    func stringParam(_ key: String) -> String? {
        guard case .object(let obj) = params, case .string(let value) = obj[key] else { return nil }
        return value
    }
}

/// CodexServerResponse：回复 Codex 服务端请求的 JSON-RPC 消息（result 或 error 二选一）。
nonisolated struct CodexServerResponse: Encodable, Sendable {
    let id: CodexRequestId
    let result: AnyCodableJSON?
    let error: ErrorPayload?

    nonisolated struct ErrorPayload: Encodable, Sendable {
        let code: Int
        let message: String
    }

    static func success(id: CodexRequestId, result: AnyCodableJSON) -> CodexServerResponse {
        CodexServerResponse(id: id, result: result, error: nil)
    }

    static func failure(id: CodexRequestId, code: Int, message: String) -> CodexServerResponse {
        CodexServerResponse(id: id, result: nil, error: ErrorPayload(code: code, message: message))
    }

    private enum CodingKeys: String, CodingKey {
        case id, result, error
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        if let error {
            try container.encode(error, forKey: .error)
        } else {
            try container.encode(result ?? .null, forKey: .result)
        }
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

    /// thread/start：显式设置 `approvalPolicy = "on-request"`（Codex 交互式默认策略：
    /// 沙箱内操作直接执行，需越过沙箱时由模型发起审批请求，经 App 权限 UI 确认）。
    /// 不覆盖 sandbox，沿用用户 Codex 配置。
    static func threadStart(id: Int, cwd: String) -> CodexRPCRequest {
        CodexRPCRequest(id: id, method: "thread/start", params: [
            "cwd": .string(cwd),
            "approvalPolicy": .string(CodexApprovalPolicy.onRequest)
        ])
    }

    /// thread/resume：按 thread ID 重新打开已保存的会话，之后的 turn/start 追加到该 thread。
    /// 与 thread/start 一样显式传 cwd 与 approvalPolicy（覆盖持久化值，保持 App 审批流程一致）。
    static func threadResume(id: Int, threadId: String, cwd: String) -> CodexRPCRequest {
        CodexRPCRequest(id: id, method: "thread/resume", params: [
            "threadId": .string(threadId),
            "cwd": .string(cwd),
            "approvalPolicy": .string(CodexApprovalPolicy.onRequest)
        ])
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

// MARK: - 服务端请求（审批）桥接

/// CodexApprovalPolicy：thread/start 的 approvalPolicy 取值（Codex `AskForApproval`，kebab-case）。
nonisolated enum CodexApprovalPolicy {
    static let untrusted = "untrusted"
    static let onRequest = "on-request"
    static let never = "never"
}

/// CodexServerRequestBridge：把 Codex 服务端请求映射为 App 权限请求，并构造回复。
/// 纯函数集合，便于单元测试。方法名与字段来自 openai/codex `app-server-protocol` v2。
nonisolated enum CodexServerRequestBridge {
    static let commandApprovalMethod = "item/commandExecution/requestApproval"
    static let fileChangeApprovalMethod = "item/fileChange/requestApproval"
    static let permissionsApprovalMethod = "item/permissions/requestApproval"
    static let mcpElicitationMethod = "mcpServer/elicitation/request"

    /// 需要经 App 权限 UI 由用户确认的请求；其他请求返回 nil。
    static func permissionRequest(for request: CodexServerRequest) -> ACPPermissionRequest? {
        switch request.method {
        case commandApprovalMethod:
            var lines: [String] = []
            lines.append(request.stringParam("command") ?? "Run command")
            if let cwd = request.stringParam("cwd") { lines.append("cwd: \(cwd)") }
            if let reason = request.stringParam("reason") { lines.append(reason) }
            return ACPPermissionRequest(
                description: lines.joined(separator: "\n"),
                tool: "commandExecution",
                options: []
            )
        case fileChangeApprovalMethod:
            var lines = ["Apply file changes"]
            if let root = request.stringParam("grantRoot") { lines.append("grant write access: \(root)") }
            if let reason = request.stringParam("reason") { lines.append(reason) }
            return ACPPermissionRequest(
                description: lines.joined(separator: "\n"),
                tool: "fileChange",
                options: []
            )
        default:
            return nil
        }
    }

    /// 用户审批结果 → 回复。accept 仅对本次生效；拒绝用 decline（让 Codex 继续本轮，而非 cancel 中断）。
    static func approvalResponse(for request: CodexServerRequest, approved: Bool) -> CodexServerResponse {
        .success(id: request.id, result: .object(["decision": .string(approved ? "accept" : "decline")]))
    }

    /// 不经 UI 的请求的默认回复：
    /// - 追加权限请求：授予空权限集（等价拒绝）；
    /// - MCP elicitation：decline；
    /// - 其他（item/tool/call、requestUserInput、token 刷新等）：JSON-RPC -32601，避免 Codex 一直等待。
    static func defaultResponse(for request: CodexServerRequest) -> CodexServerResponse {
        switch request.method {
        case permissionsApprovalMethod:
            return .success(id: request.id, result: .object([
                "permissions": .object([:]),
                "scope": .string("turn")
            ]))
        case mcpElicitationMethod:
            return .success(id: request.id, result: .object([
                "action": .string("decline"),
                "content": .null
            ]))
        default:
            return .failure(id: request.id, code: -32601, message: "Method not supported by ConchTalk: \(request.method)")
        }
    }
}
