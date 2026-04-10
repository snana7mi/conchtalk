/// 文件说明：ChatViewModelAttachmentTests，覆盖附件添加与本地状态管理行为。
import Testing
@testable import ConchTalk
import Foundation

@Suite("ChatViewModel Attachments")
@MainActor
struct ChatViewModelAttachmentTests {
    @Test("addAttachments 会追加有效附件")
    func addAttachments_appendsValidFiles() async throws {
        let store = try ChatViewModelTestSupport.makeInMemoryStore()
        let server = TestFixtures.makeServer()
        try await store.saveServer(server)

        let viewModel = ChatViewModelTestSupport.makeViewModel(server: server, store: store)
        let tempURL = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appendingPathExtension("txt")
        try Data("hello".utf8).write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let oversized = viewModel.addAttachments(from: [tempURL])

        #expect(oversized.isEmpty)
        #expect(viewModel.attachments.count == 1)
        #expect(viewModel.attachments.first?.fileName == tempURL.lastPathComponent)
    }

    @Test("removeAttachment 和 clearAttachments 只更新本地附件状态")
    func removeAndClearAttachments_updateLocalState() async throws {
        let store = try ChatViewModelTestSupport.makeInMemoryStore()
        let server = TestFixtures.makeServer()
        try await store.saveServer(server)

        let viewModel = ChatViewModelTestSupport.makeViewModel(server: server, store: store)
        let first = TestFixtures.makeFileAttachment(fileName: "a.txt")
        let second = TestFixtures.makeFileAttachment(fileName: "b.txt")
        viewModel.attachments = [first, second]

        viewModel.removeAttachment(first)
        #expect(viewModel.attachments.map(\.fileName) == ["b.txt"])

        viewModel.clearAttachments()
        #expect(viewModel.attachments.isEmpty)
    }
}
