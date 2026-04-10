/// 文件说明：ChatViewModelMetadataTests，覆盖确认文案格式化行为。
import Testing
@testable import ConchTalk
import Foundation

@Suite("ChatViewModel Metadata")
@MainActor
struct ChatViewModelMetadataTests {
    @Test("confirmationMessage 会格式化 execute_ssh_command")
    func confirmationMessage_formatsExecuteSSHCommand() async throws {
        let store = try ChatViewModelTestSupport.makeInMemoryStore()
        let server = TestFixtures.makeServer()
        try await store.saveServer(server)

        let viewModel = ChatViewModelTestSupport.makeViewModel(server: server, store: store)
        let toolCall = TestFixtures.makeToolCall(
            toolName: "execute_ssh_command",
            arguments: ["command": "ls -la"],
            explanation: "Run command"
        )

        let message = viewModel.confirmationMessage(for: toolCall)

        #expect(message.contains("Run command"))
        #expect(message.contains("$ ls -la"))
    }
}
