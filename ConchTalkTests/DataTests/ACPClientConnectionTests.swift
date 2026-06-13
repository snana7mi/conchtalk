/// 文件说明：ACPClientConnectionTests，覆盖 ACPClientConnection 的请求响应竞态。

import Testing
import Foundation
@testable import ConchTalk
@preconcurrency import ACPModel

@Suite("ACPClientConnection")
struct ACPClientConnectionTests {
    actor ImmediateResponseTransport: ACPTransport {
        nonisolated let messages: AsyncThrowingStream<ACPMessage, Error>
        private let continuation: AsyncThrowingStream<ACPMessage, Error>.Continuation

        init() {
            let (stream, continuation) = AsyncThrowingStream<ACPMessage, Error>.makeStream()
            self.messages = stream
            self.continuation = continuation
        }

        func start() async throws {}

        func send(_ message: ACPMessage) async throws {
            guard case .request(let request) = message else { return }

            switch request.method {
            case "initialize":
                let result = InitializeResponse(
                    protocolVersion: 1,
                    agentCapabilities: AgentCapabilities(),
                    agentInfo: AgentInfo(name: "Kimi Code CLI", version: "1.0")
                )
                continuation.yield(.response(JSONRPCResponse(
                    id: request.id,
                    result: try Self.encode(result),
                    error: nil
                )))
            default:
                break
            }

            // 模拟远端极快返回，确保 router 有机会在 send() 返回前消费响应。
            await Task.yield()
        }

        func close() async {
            continuation.finish()
        }

        private static func encode<T: Encodable>(_ value: T) throws -> AnyCodable {
            let data = try JSONEncoder().encode(value)
            return try JSONDecoder().decode(AnyCodable.self, from: data)
        }
    }

    @Test("响应在 send 返回前到达时 connect 仍能成功")
    func connect_succeedsWhenResponseArrivesImmediately() async throws {
        let transport = ImmediateResponseTransport()
        let connection = ACPClientConnection(transport: transport, requestTimeoutSeconds: 0.1)

        let result = try await connection.connect()

        #expect(result.protocolVersion == 1)
        #expect(result.agentInfo?.name == "Kimi Code CLI")

        await connection.disconnect()
    }

    /// 完全静默的 transport：start/send 均无响应，用于固定超时回归。
    actor TotallySilentTransport: ACPTransport {
        nonisolated let messages: AsyncThrowingStream<ACPMessage, Error>
        private let continuation: AsyncThrowingStream<ACPMessage, Error>.Continuation

        init() {
            let (stream, continuation) = AsyncThrowingStream<ACPMessage, Error>.makeStream()
            self.messages = stream
            self.continuation = continuation
        }

        func start() async throws {}
        func send(_ message: ACPMessage) async throws {}
        func close() async { continuation.finish() }
    }

    /// 可编程 prompt 行为的 transport：initialize 正常响应，session/prompt 按配置处理。
    actor ScriptedPromptTransport: ACPTransport {
        enum PromptBehavior {
            /// 完全静默（不回 response、不发通知）
            case silent
            /// 周期发 session/update 通知 count 次（间隔 interval）后回正常 response
            case updatesThenRespond(count: Int, interval: Duration)
            /// 收到 prompt 后 finish 消息流（模拟代理进程退出）
            case closeStream
        }

        nonisolated let messages: AsyncThrowingStream<ACPMessage, Error>
        private let continuation: AsyncThrowingStream<ACPMessage, Error>.Continuation
        private let promptBehavior: PromptBehavior

        init(promptBehavior: PromptBehavior) {
            let (stream, continuation) = AsyncThrowingStream<ACPMessage, Error>.makeStream()
            self.messages = stream
            self.continuation = continuation
            self.promptBehavior = promptBehavior
        }

        func start() async throws {}

        func send(_ message: ACPMessage) async throws {
            guard case .request(let request) = message else { return }
            switch request.method {
            case "initialize":
                let result = InitializeResponse(
                    protocolVersion: 1,
                    agentCapabilities: AgentCapabilities(),
                    agentInfo: AgentInfo(name: "Test Agent", version: "1.0")
                )
                continuation.yield(.response(JSONRPCResponse(
                    id: request.id, result: try Self.encode(result), error: nil)))
            case "session/prompt":
                switch promptBehavior {
                case .silent:
                    break
                case .updatesThenRespond(let count, let interval):
                    let id = request.id
                    let cont = continuation
                    Task {
                        let updateJSON = """
                        {"sessionId": "sess-test", "update": {"sessionUpdate": "agent_message_chunk", \
                        "content": {"type": "text", "text": "working"}}}
                        """
                        let params = try? JSONDecoder().decode(
                            AnyCodable.self, from: Data(updateJSON.utf8))
                        for _ in 0..<count {
                            try? await Task.sleep(for: interval)
                            cont.yield(.notification(JSONRPCNotification(
                                method: "session/update", params: params)))
                        }
                        let result = try? JSONDecoder().decode(
                            AnyCodable.self, from: Data(#"{"stopReason": "end_turn"}"#.utf8))
                        cont.yield(.response(JSONRPCResponse(id: id, result: result, error: nil)))
                    }
                case .closeStream:
                    continuation.finish()
                }
            default:
                break
            }
            await Task.yield()
        }

        func close() async { continuation.finish() }

        private static func encode<T: Encodable>(_ value: T) throws -> AnyCodable {
            let data = try JSONEncoder().encode(value)
            return try JSONDecoder().decode(AnyCodable.self, from: data)
        }
    }

    // MARK: - prompt 空闲超时（问题 3）

    @Test("prompt 静默超过空闲上限时抛 timeout")
    func prompt_idleTimeoutFiresWhenSilent() async throws {
        let transport = ScriptedPromptTransport(promptBehavior: .silent)
        let connection = ACPClientConnection(
            transport: transport, requestTimeoutSeconds: 5, promptIdleTimeoutSeconds: 0.2)
        _ = try await connection.connect()

        do {
            _ = try await connection.prompt(sessionId: SessionId("sess-test"), text: "hi")
            Issue.record("Expected timeout but prompt returned")
        } catch let error as ACPConnectionError {
            guard case .timeout = error else {
                Issue.record("Expected .timeout but got \(error)")
                return
            }
        }
        await connection.disconnect()
    }

    @Test("session/update 持续到达时 prompt 不超时并正常返回")
    func prompt_sessionUpdatesRenewIdleTimeout() async throws {
        // idle 0.3s；通知间隔 0.1s × 8 次（总时长约 0.8s，远超 idle 上限）后回 response
        let transport = ScriptedPromptTransport(
            promptBehavior: .updatesThenRespond(count: 8, interval: .milliseconds(100)))
        let connection = ACPClientConnection(
            transport: transport, requestTimeoutSeconds: 5, promptIdleTimeoutSeconds: 0.3)
        _ = try await connection.connect()

        let response = try await connection.prompt(sessionId: SessionId("sess-test"), text: "hi")
        #expect(response.stopReason == .endTurn)
        await connection.disconnect()
    }

    @Test("initialize 仍按固定超时抛错（回归）")
    func initialize_fixedTimeoutUnchanged() async throws {
        let transport = TotallySilentTransport()
        let connection = ACPClientConnection(transport: transport, requestTimeoutSeconds: 0.1)

        do {
            _ = try await connection.connect()
            Issue.record("Expected timeout but connect succeeded")
        } catch let error as ACPConnectionError {
            guard case .timeout = error else {
                Issue.record("Expected .timeout but got \(error)")
                return
            }
        }
        await connection.disconnect()
    }

    @Test("prompt 挂起期间 transport 关闭立即失败，不等空闲超时（回归）")
    func prompt_transportClosedFailsImmediately() async throws {
        let transport = ScriptedPromptTransport(promptBehavior: .closeStream)
        let connection = ACPClientConnection(
            transport: transport, requestTimeoutSeconds: 5, promptIdleTimeoutSeconds: 60)
        _ = try await connection.connect()

        let start = ContinuousClock.now
        do {
            _ = try await connection.prompt(sessionId: SessionId("sess-test"), text: "hi")
            Issue.record("Expected disconnected but prompt returned")
        } catch let error as ACPConnectionError {
            guard case .disconnected = error else {
                Issue.record("Expected .disconnected but got \(error)")
                return
            }
        }
        #expect(ContinuousClock.now - start < .seconds(5))
        await connection.disconnect()
    }

    /// 记录响应的 transport：initialize 正常响应，capture connection 回写的 response 供断言；
    /// 提供 injectAgentRequest 由测试主动注入代理→客户端请求。
    actor PermissionRequestTransport: ACPTransport {
        nonisolated let messages: AsyncThrowingStream<ACPMessage, Error>
        private let continuation: AsyncThrowingStream<ACPMessage, Error>.Continuation
        private(set) var sentResponses: [JSONRPCResponse] = []

        init() {
            let (stream, continuation) = AsyncThrowingStream<ACPMessage, Error>.makeStream()
            self.messages = stream
            self.continuation = continuation
        }

        func start() async throws {}

        func send(_ message: ACPMessage) async throws {
            switch message {
            case .request(let request) where request.method == "initialize":
                let result = InitializeResponse(
                    protocolVersion: 1,
                    agentCapabilities: AgentCapabilities(),
                    agentInfo: AgentInfo(name: "Test Agent", version: "1.0")
                )
                let data = try JSONEncoder().encode(result)
                let anyCodable = try JSONDecoder().decode(AnyCodable.self, from: data)
                continuation.yield(.response(JSONRPCResponse(
                    id: request.id, result: anyCodable, error: nil)))
            case .response(let response):
                sentResponses.append(response)
            default:
                break
            }
            await Task.yield()
        }

        func close() async { continuation.finish() }

        /// 注入代理→客户端的请求（params 用 JSON 字符串构造）。
        func injectAgentRequest(id: Int, method: String, paramsJSON: String) throws {
            let params = try JSONDecoder().decode(AnyCodable.self, from: Data(paramsJSON.utf8))
            continuation.yield(.request(JSONRPCRequest(id: .number(id), method: method, params: params)))
        }

        /// 轮询等待 connection 回写第一条响应。
        func waitForFirstResponse(timeoutMs: Int = 2_000) async -> JSONRPCResponse? {
            for _ in 0..<(timeoutMs / 10) {
                if let first = sentResponses.first { return first }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return sentResponses.first
        }
    }

    /// 规范权限请求 JSON（{sessionId, toolCall, options}，无 description 键）。
    private static let specPermissionParamsJSON = """
    {"sessionId": "sess-1",
     "toolCall": {"toolCallId": "tc-1", "title": "Edit main.swift", "kind": "edit"},
     "options": [
        {"optionId": "opt-allow-once", "name": "Allow once", "kind": "allow_once"},
        {"optionId": "opt-reject-once", "name": "Reject once", "kind": "reject_once"}
     ]}
    """

    /// 解析响应 result 为规范 outcome 结构。
    private func decodeOutcome(_ response: JSONRPCResponse) throws -> RequestPermissionResponse {
        let data = try JSONEncoder().encode(try #require(response.result))
        return try JSONDecoder().decode(RequestPermissionResponse.self, from: data)
    }

    // MARK: - session/request_permission 规范化（问题 2）

    @Test("规范权限请求解码并按 approve 选择 allow_once 选项")
    func requestPermission_specCompliantDecodeAndApprove() async throws {
        let transport = PermissionRequestTransport()
        let connection = ACPClientConnection(transport: transport, requestTimeoutSeconds: 5)

        let receivedRequest = LockedBox<ACPPermissionRequest?>(nil)
        await connection.setPermissionHandler { request in
            receivedRequest.set(request)
            return true
        }
        _ = try await connection.connect()

        try await transport.injectAgentRequest(
            id: 42, method: "session/request_permission",
            paramsJSON: Self.specPermissionParamsJSON)

        let response = try #require(await transport.waitForFirstResponse())
        // handler 收到正确桥接的请求
        let bridged = try #require(receivedRequest.withValue { $0 })
        #expect(bridged.description == "Edit main.swift")
        #expect(bridged.tool == "edit")
        #expect(bridged.options.count == 2)
        #expect(bridged.options.first?.kind == "allow_once")
        // 响应为规范 outcome 结构
        let outcome = try decodeOutcome(response)
        #expect(outcome.outcome.outcome == "selected")
        #expect(outcome.outcome.optionId == "opt-allow-once")

        await connection.disconnect()
    }

    @Test("deny 时选择 reject_once 选项")
    func requestPermission_denySelectsRejectOption() async throws {
        let transport = PermissionRequestTransport()
        let connection = ACPClientConnection(transport: transport, requestTimeoutSeconds: 5)
        await connection.setPermissionHandler { _ in false }
        _ = try await connection.connect()

        try await transport.injectAgentRequest(
            id: 43, method: "session/request_permission",
            paramsJSON: Self.specPermissionParamsJSON)

        let response = try #require(await transport.waitForFirstResponse())
        let outcome = try decodeOutcome(response)
        #expect(outcome.outcome.outcome == "selected")
        #expect(outcome.outcome.optionId == "opt-reject-once")

        await connection.disconnect()
    }

    @Test("未注册 handler 时按规范回 cancelled 而非裸 false")
    func requestPermission_noHandlerRespondsCancelled() async throws {
        let transport = PermissionRequestTransport()
        let connection = ACPClientConnection(transport: transport, requestTimeoutSeconds: 5)
        _ = try await connection.connect()

        try await transport.injectAgentRequest(
            id: 44, method: "session/request_permission",
            paramsJSON: Self.specPermissionParamsJSON)

        let response = try #require(await transport.waitForFirstResponse())
        let outcome = try decodeOutcome(response)
        #expect(outcome.outcome.outcome == "cancelled")
        #expect(outcome.outcome.optionId == nil)

        await connection.disconnect()
    }

    @Test("旧 {description, tool} 线格式 fallback 解码且响应保持裸布尔")
    func requestPermission_legacyShapeFallback() async throws {
        let transport = PermissionRequestTransport()
        let connection = ACPClientConnection(transport: transport, requestTimeoutSeconds: 5)

        let receivedRequest = LockedBox<ACPPermissionRequest?>(nil)
        await connection.setPermissionHandler { request in
            receivedRequest.set(request)
            return true
        }
        _ = try await connection.connect()

        try await transport.injectAgentRequest(
            id: 45, method: "session/request_permission",
            paramsJSON: #"{"description": "Run npm install", "tool": "execute"}"#)

        let response = try #require(await transport.waitForFirstResponse())
        let bridged = try #require(receivedRequest.withValue { $0 })
        #expect(bridged.description == "Run npm install")
        #expect(bridged.options.isEmpty)
        // 旧格式响应保持裸布尔（兼容非标代理）
        let data = try JSONEncoder().encode(try #require(response.result))
        let approved = try JSONDecoder().decode(Bool.self, from: data)
        #expect(approved)

        await connection.disconnect()
    }

    @Test("selectOutcome 的 kind 匹配与回退规则")
    func selectOutcome_kindMatchingRules() {
        let options = [
            PermissionOption(kind: "allow_always", name: "Always", optionId: "a-always"),
            PermissionOption(kind: "reject_once", name: "Reject", optionId: "r-once"),
        ]
        // approve 无 allow_once → 回退首个 allow* 前缀
        let approved = ACPClientConnection.selectOutcome(approved: true, options: options)
        #expect(approved.optionId == "a-always")
        // deny 精确命中 reject_once
        let denied = ACPClientConnection.selectOutcome(approved: false, options: options)
        #expect(denied.optionId == "r-once")
        // options 为空 → cancelled
        let cancelled = ACPClientConnection.selectOutcome(approved: true, options: [])
        #expect(cancelled.outcome == "cancelled")
        #expect(cancelled.optionId == nil)
    }
}
