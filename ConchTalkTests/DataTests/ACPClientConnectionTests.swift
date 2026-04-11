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
}
