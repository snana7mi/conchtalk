/// 文件说明：ACPTransport，ACP 消息传输抽象协议。

import Foundation
@preconcurrency import ACPModel

/// 避免与 Domain 层 Message 冲突的类型别名。
typealias ACPMessage = ACPModel.Message

/// ACPTransport：定义 ACP 消息传输的抽象接口。
/// 不同的传输实现（SSH、本地 stdio 等）遵循此协议。
protocol ACPTransport: Sendable {
    /// 启动传输，建立底层连接。
    func start() async throws
    /// 发送一条 JSON-RPC 消息。
    func send(_ message: ACPMessage) async throws
    /// 接收消息的异步流。
    nonisolated var messages: AsyncThrowingStream<ACPMessage, Error> { get }
    /// 关闭传输，释放资源。
    func close() async
}
