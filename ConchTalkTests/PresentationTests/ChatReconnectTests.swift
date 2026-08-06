/// 文件说明：ChatReconnectTests，验证聊天页重连、断线恢复与状态清理逻辑。
import Testing
@testable import ConchTalk
import Foundation
import SwiftData

@Suite("Chat Reconnect")
@MainActor
struct ChatReconnectTests {
    @Test("原地自动重连失败后退出重连状态并保留断线消息")
    func inPlaceReconnectFailureClearsReconnectingAndKeepsLostMessage() async throws {
        let store = try ChatViewModelTestSupport.makeInMemoryStore()
        let server = TestFixtures.makeServer()

        try await store.saveServer(server)

        let viewModel = ChatViewModelTestSupport.makeViewModel(server: server, store: store)
        await viewModel.loadMessages()

        let result = await viewModel.attemptInPlaceReconnect(recordLostMessage: true)

        #expect(result == false)
        #expect(viewModel.isReconnecting == false)
        #expect(viewModel.isConnected == false)
        #expect(viewModel.messages.contains(where: { $0.systemMessageType == .connectionLost }))
    }

    @Test("后台原地自动重连失败后会追加明确失败消息")
    func inPlaceReconnectFailureAppendsFailureMessage() async throws {
        let store = try ChatViewModelTestSupport.makeInMemoryStore()
        let server = TestFixtures.makeServer()

        try await store.saveServer(server)

        let viewModel = ChatViewModelTestSupport.makeViewModel(server: server, store: store)
        await viewModel.loadMessages()

        let result = await viewModel.attemptInPlaceReconnect(
            recordLostMessage: false,
            failureMessage: "Auto-reconnect failed, returning to server list"
        )

        #expect(result == false)
        #expect(
            viewModel.messages.contains(where: {
                $0.systemMessageType == .connectionFailed &&
                $0.content.contains("Auto-reconnect failed, returning to server list")
            })
        )
    }

    @Test("disconnect 会清理瞬时状态并追加 disconnected 系统消息")
    func disconnect_clearsTransientStateAndAppendsDisconnectedMessage() async throws {
        let store = try ChatViewModelTestSupport.makeInMemoryStore()
        let server = TestFixtures.makeServer()

        try await store.saveServer(server)

        let viewModel = ChatViewModelTestSupport.makeViewModel(server: server, store: store)
        await viewModel.loadMessages()
        viewModel.isConnected = true
        viewModel.isProcessing = true
        viewModel.showConfirmation = true
        viewModel.pendingToolCall = TestFixtures.makeToolCall()
        viewModel.isStreaming = true
        viewModel.isReasoningActive = true
        viewModel.activeReasoningText = "thinking"
        viewModel.activeContentText = "typing"
        viewModel.liveToolOutput = "tool"
        viewModel.agentStreamEvents = [.text("delta")]
        viewModel.isAgentExecuting = true
        viewModel.messages.append(TestFixtures.makeMessage(role: .assistant, content: "", isLoading: true))

        await viewModel.disconnect()

        #expect(viewModel.isConnected == false)
        #expect(viewModel.isProcessing == false)
        #expect(viewModel.showConfirmation == false)
        #expect(viewModel.pendingToolCall == nil)
        #expect(viewModel.isStreaming == false)
        #expect(viewModel.isReasoningActive == false)
        #expect(viewModel.activeReasoningText.isEmpty)
        #expect(viewModel.activeContentText.isEmpty)
        #expect(viewModel.liveToolOutput == nil)
        #expect(viewModel.agentStreamEvents.isEmpty)
        #expect(viewModel.isAgentExecuting == false)
        #expect(viewModel.messages.contains(where: { $0.systemMessageType == .disconnected }))
        #expect(viewModel.messages.contains(where: { $0.isLoading }) == false)
    }
}
