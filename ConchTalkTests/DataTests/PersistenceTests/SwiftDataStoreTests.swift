/// 文件说明：SwiftDataStoreTests，覆盖批量消息写入与系统环境持久化关键回归路径。
import Testing
@testable import ConchTalk
import Foundation
import SwiftData

@Suite("SwiftDataStore")
struct SwiftDataStoreTests {
    private func makeInMemoryStore() throws -> (store: SwiftDataStore, container: ModelContainer) {
        let schema = Schema([
            ServerModel.self,
            MessageModel.self,
            ServerGroupModel.self,
            SSHKeyModel.self,
            MemoryModel.self,
            MemoryEntryModel.self,
            SystemProfileModel.self,
        ])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        return (SwiftDataStore(modelContainer: container), container)
    }

    @Test("addMessages 批量写入会去重并保持幂等")
    func addMessagesDeduplicatesAndIsIdempotent() async throws {
        let (store, _) = try makeInMemoryStore()
        let serverID = UUID()

        let message1ID = UUID()
        let message2ID = UUID()
        let message1 = TestFixtures.makeMessage(id: message1ID, role: .assistant, content: "first")
        let message1Duplicate = TestFixtures.makeMessage(id: message1ID, role: .assistant, content: "first duplicate")
        let message2 = TestFixtures.makeMessage(id: message2ID, role: .assistant, content: "second")

        try await store.addMessages([message1, message1Duplicate, message2], toServer: serverID)
        try await store.addMessages([message1, message2], toServer: serverID)

        let messages = try await store.fetchMessages(forServer: serverID)
        #expect(messages.count == 2)

        let messageIDs = Set(messages.map(\.id))
        #expect(messageIDs.contains(message1ID))
        #expect(messageIDs.contains(message2ID))
    }

    @Test("addMessages 对不存在的 server 静默写入（serverID 直接绑定消息）")
    func addMessagesSilentlySucceeds() async throws {
        let (store, _) = try makeInMemoryStore()
        let message = TestFixtures.makeMessage(content: "orphan message")
        let serverID = UUID()

        // 在新架构下，消息直接绑定 serverID，无需预先创建服务器记录
        try await store.addMessages([message], toServer: serverID)

        let messages = try await store.fetchMessages(forServer: serverID)
        #expect(messages.count == 1)
    }

    @Test("upsertSystemProfile 会更新同 serverID 的已存在记录")
    func upsertSystemProfileUpdatesExistingRecord() async throws {
        let (store, _) = try makeInMemoryStore()
        let serverID = UUID()

        let initialProfile = SystemProfile(
            serverID: serverID,
            detectedAt: Date(timeIntervalSince1970: 1),
            osInfo: "Linux",
            packageManager: "apt",
            installedTools: [
                .init(name: "tmux", available: false, version: nil, path: nil),
            ]
        )
        let updatedProfile = SystemProfile(
            serverID: serverID,
            detectedAt: Date(timeIntervalSince1970: 2),
            osInfo: "Ubuntu 24.04",
            packageManager: "dnf",
            installedTools: [
                .init(name: "tmux", available: true, version: "tmux 3.4", path: "/usr/bin/tmux"),
                .init(name: "jq", available: true, version: "jq-1.7", path: "/usr/bin/jq"),
            ]
        )

        try await store.upsertSystemProfile(initialProfile)
        try await store.upsertSystemProfile(updatedProfile)

        let fetched = try await store.fetchSystemProfile(forServer: serverID)
        #expect(fetched != nil)
        #expect(fetched?.osInfo == "Ubuntu 24.04")
        #expect(fetched?.packageManager == "dnf")
        #expect(fetched?.installedTools.count == 2)
        #expect(fetched?.installedTools.first(where: { $0.name == "tmux" })?.available == true)
    }

    @Test("fetchSystemProfile 在持久化数据损坏时抛出解码错误")
    func fetchSystemProfileThrowsOnCorruptedToolsJSON() async throws {
        let (store, container) = try makeInMemoryStore()
        let serverID = UUID()
        let corrupted = SystemProfileModel(
            serverID: serverID,
            osInfo: "Linux",
            packageManager: "apt",
            toolsJSON: "{invalid-json}",
            detectedAt: Date()
        )
        container.mainContext.insert(corrupted)
        try container.mainContext.save()

        await #expect(throws: SystemProfileModelError.self) {
            _ = try await store.fetchSystemProfile(forServer: serverID)
        }
    }
}

// MARK: - ChatMessageRepository Tests

@Suite("ChatMessageRepository")
struct ChatMessageRepositoryTests {
    private func makeInMemoryStore() throws -> SwiftDataStore {
        let schema = Schema([
            ServerModel.self,
            MessageModel.self,
            ServerGroupModel.self,
            SSHKeyModel.self,
            MemoryModel.self,
            MemoryEntryModel.self,
            SystemProfileModel.self,
        ])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        return SwiftDataStore(modelContainer: container)
    }

    @Test("appendSystemMessage 持久化预期的 systemMessageType")
    func appendSystemMessage_persistsExpectedSystemType() async throws {
        let store = try makeInMemoryStore()
        let repo = ChatMessageRepository(store: store)
        let serverID = UUID()

        try await repo.appendSystemMessage(
            "Server connected",
            type: .connected,
            toServer: serverID
        )

        let messages = try await repo.reloadMessages(forServer: serverID)
        #expect(messages.count == 1)
        #expect(messages.first?.role == .system)
        #expect(messages.first?.systemMessageType == .connected)
        #expect(messages.first?.content == "Server connected")
    }

    @Test("appendAIContextMessage 持久化隐藏系统消息")
    func appendAIContextMessage_persistsHiddenSystemMessage() async throws {
        let store = try makeInMemoryStore()
        let repo = ChatMessageRepository(store: store)
        let serverID = UUID()

        try await repo.appendAIContextMessage(
            "Context info for AI",
            toServer: serverID
        )

        let messages = try await repo.reloadMessages(forServer: serverID)
        #expect(messages.count == 1)
        #expect(messages.first?.role == .system)
        #expect(messages.first?.systemMessageType == .aiContext)
        #expect(messages.first?.content == "Context info for AI")
    }

    @Test("reloadMessages 按时间戳顺序返回消息")
    func reloadMessages_returnsMessagesInTimestampOrder() async throws {
        let store = try makeInMemoryStore()
        let repo = ChatMessageRepository(store: store)
        let serverID = UUID()

        let now = Date()
        let msg1 = TestFixtures.makeMessage(
            role: .user,
            content: "first",
            timestamp: now.addingTimeInterval(-2)
        )
        let msg2 = TestFixtures.makeMessage(
            role: .assistant,
            content: "second",
            timestamp: now.addingTimeInterval(-1)
        )
        let msg3 = TestFixtures.makeMessage(
            role: .user,
            content: "third",
            timestamp: now
        )

        // 故意乱序写入
        try await repo.appendMessages([msg3, msg1, msg2], toServer: serverID)

        let messages = try await repo.reloadMessages(forServer: serverID)
        #expect(messages.count == 3)
        #expect(messages[0].content == "first")
        #expect(messages[1].content == "second")
        #expect(messages[2].content == "third")
    }

    @Test("appendMessage 单条追加并持久化")
    func appendMessage_persistsSingleMessage() async throws {
        let store = try makeInMemoryStore()
        let repo = ChatMessageRepository(store: store)
        let serverID = UUID()

        let msg = TestFixtures.makeMessage(role: .user, content: "hello")
        try await repo.appendMessage(msg, toServer: serverID)

        let messages = try await repo.reloadMessages(forServer: serverID)
        #expect(messages.count == 1)
        #expect(messages.first?.content == "hello")
    }

    @Test("appendContextBreak 持久化上下文断点消息")
    func appendContextBreak_persistsContextBreakMessage() async throws {
        let store = try makeInMemoryStore()
        let repo = ChatMessageRepository(store: store)
        let serverID = UUID()

        try await repo.appendContextBreak(toServer: serverID)

        let messages = try await repo.reloadMessages(forServer: serverID)
        #expect(messages.count == 1)
        #expect(messages.first?.role == .system)
        #expect(messages.first?.systemMessageType == .contextBreak)
    }
}
