/// 文件说明：SwiftDataStoreMessagePaginationTests，验证消息分页查询的游标逻辑。
import Testing
@testable import ConchTalk
import Foundation
import SwiftData

@Suite("SwiftDataStore Message Pagination")
@MainActor
struct SwiftDataStoreMessagePaginationTests {

    /// 创建内存 SwiftDataStore 用于测试。
    private func makeStore() throws -> SwiftDataStore {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: MessageModel.self, ServerModel.self,
            configurations: config
        )
        return SwiftDataStore(modelContainer: container)
    }

    /// 批量插入带递增时间戳的消息。
    private func insertMessages(store: SwiftDataStore, serverID: UUID, count: Int) async throws -> [Message] {
        let base = Date(timeIntervalSince1970: 1_000_000)
        var messages: [Message] = []
        for i in 0..<count {
            let msg = TestFixtures.makeMessage(
                role: .user,
                content: "Message \(i)",
                timestamp: base.addingTimeInterval(Double(i))
            )
            messages.append(msg)
        }
        try await store.addMessages(messages, toServer: serverID)
        return messages
    }

    @Test("fetchRecentMessages 返回最近 N 条，按时间升序")
    func fetchRecentMessages_returnsLatestN() async throws {
        let store = try makeStore()
        let serverID = UUID()
        let all = try await insertMessages(store: store, serverID: serverID, count: 10)

        let recent = try await store.fetchRecentMessages(forServer: serverID, limit: 3)

        #expect(recent.count == 3)
        #expect(recent[0].id == all[7].id)
        #expect(recent[1].id == all[8].id)
        #expect(recent[2].id == all[9].id)
    }

    @Test("fetchRecentMessages limit 超过总数时返回全部")
    func fetchRecentMessages_limitExceedsTotal() async throws {
        let store = try makeStore()
        let serverID = UUID()
        let all = try await insertMessages(store: store, serverID: serverID, count: 5)

        let recent = try await store.fetchRecentMessages(forServer: serverID, limit: 100)

        #expect(recent.count == 5)
        #expect(recent[0].id == all[0].id)
    }

    @Test("fetchOlderMessages 返回游标之前的消息")
    func fetchOlderMessages_returnsBefore() async throws {
        let store = try makeStore()
        let serverID = UUID()
        let all = try await insertMessages(store: store, serverID: serverID, count: 10)

        // 用第 5 条消息作为游标（索引 5），应返回索引 2, 3, 4
        let older = try await store.fetchOlderMessages(
            forServer: serverID,
            limit: 3,
            beforeTimestamp: all[5].timestamp,
            beforeID: all[5].id
        )

        #expect(older.count == 3)
        #expect(older[0].id == all[2].id) // 升序返回
        #expect(older[1].id == all[3].id)
        #expect(older[2].id == all[4].id)
    }

    @Test("fetchOlderMessages 游标在最前时返回空")
    func fetchOlderMessages_emptyAtBeginning() async throws {
        let store = try makeStore()
        let serverID = UUID()
        let all = try await insertMessages(store: store, serverID: serverID, count: 5)

        let older = try await store.fetchOlderMessages(
            forServer: serverID,
            limit: 10,
            beforeTimestamp: all[0].timestamp,
            beforeID: all[0].id
        )

        #expect(older.isEmpty)
    }

    @Test("fetchOlderMessages 处理相同时间戳的消息")
    func fetchOlderMessages_handlesIdenticalTimestamps() async throws {
        let store = try makeStore()
        let serverID = UUID()
        let sameTime = Date(timeIntervalSince1970: 1_000_000)

        // 3 条消息共享同一时间戳
        let ids = [UUID(), UUID(), UUID()]
        let sortedIDs = ids.sorted { $0.uuidString < $1.uuidString }

        for id in ids {
            let msg = TestFixtures.makeMessage(id: id, role: .user, content: "msg", timestamp: sameTime)
            try await store.addMessage(msg, toServer: serverID)
        }

        // 用排序后最大的 ID 作为游标
        let cursor = sortedIDs.last!
        let older = try await store.fetchOlderMessages(
            forServer: serverID,
            limit: 10,
            beforeTimestamp: sameTime,
            beforeID: cursor
        )

        // 应返回同时间戳中 ID 更小的消息
        #expect(older.count == 2)
        #expect(!older.contains { $0.id == cursor })
    }
}
